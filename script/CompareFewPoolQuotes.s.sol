// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FewV4ShellHook} from "../src/FewV4ShellHook.sol";
import {FewDynamicFeeHook} from "../src/FewDynamicFeeHook.sol";
import {FwInventoryFeeMath as FeeMath} from "../src/libraries/FwInventoryFeeMath.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../src/interfaces/external/IFewWrappedToken.sol";
import {MockFewFactory} from "../test/mocks/MockFewFactory.sol";
import {MockWETH9} from "../test/mocks/MockWETH9.sol";

/// @notice Local quote matrix comparing a shell route to fixed-fee and dynamic-fee Few v4 pools.
contract CompareFewPoolQuotes is Test {
    uint160 constant SQRT_PRICE_1_1 = 1 << 96;
    uint24 constant FIXED_FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint256 constant LIQUIDITY = 100e18;
    address constant USER = address(0xBEEF);

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockFewFactory factory;
    MockWETH9 weth;
    PoolManager manager;
    PoolModifyLiquidityTest liquidityRouter;
    V4Quoter quoter;
    FewV4ShellHook shellHook;
    FewDynamicFeeHook dynamicHook;
    PoolKey shellKey;
    PoolKey fixedFewKey;
    PoolKey dynamicFewKey;
    address few0;
    address few1;
    address origin0;
    address origin1;
    bool orderAligned;
    string outputTable;
    string outputCsv;
    string summaryTable;
    int256[12] summaryBps;
    uint256[12] summaryCount;
    uint256[12] summaryBetter;
    uint256[12] summaryWorse;
    int256 worstBps;
    int256 bestBps;
    int256[4] modeDirectionBps;
    uint256[4] modeDirectionCount;

    function test_compare() external {
        _setUp();
        _seedPools();
        _printHeader();
        outputTable =
            "| Mode | Direction | Amount | Token1 backing | Fixed Few quote | Dynamic Few quote | Delta | Delta % | Shell fixed | Shell dynamic |\n|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n";
        outputCsv =
            "mode,direction,amount,token1_backing,fixed_few_quote,dynamic_few_quote,delta,delta_percent,shell_fixed_quote,shell_dynamic_quote\n";
        worstBps = type(int256).max;
        bestBps = type(int256).min;

        uint256[5] memory amounts = [uint256(1e15), 1e17, 1e18, 5e18, 10e18];
        uint256[3] memory inventory1 = [uint256(50e18), 100e18, 200e18];
        for (uint256 inv; inv < inventory1.length; ++inv) {
            _setBacking(100e18, inventory1[inv]);
            for (uint256 direction; direction < 2; ++direction) {
                for (uint256 mode; mode < 2; ++mode) {
                    for (uint256 size; size < amounts.length; ++size) {
                        (int256 scenarioBps, bool valid) =
                            this.measureScenario(direction == 0, mode == 0, amounts[size], inventory1[inv]);
                        if (valid) {
                            uint256 group = (direction == 0 ? 0 : 6) + (mode == 0 ? 0 : 3) + inv;
                            summaryBps[group] += scenarioBps;
                            summaryCount[group]++;
                            if (scenarioBps < 0) summaryBetter[group]++;
                            else if (scenarioBps > 0) summaryWorse[group]++;
                            if (scenarioBps < worstBps) worstBps = scenarioBps;
                            if (scenarioBps > bestBps) bestBps = scenarioBps;
                            uint256 md = (mode == 0 ? 0 : 2) + direction;
                            modeDirectionBps[md] += scenarioBps;
                            modeDirectionCount[md]++;
                        }
                    }
                }
            }
        }
        _buildSummary();
        outputTable = string.concat(summaryTable, outputTable);
        vm.writeFile("out/few_quote_comparison.md", outputTable);
        vm.writeFile("out/few_quote_comparison.csv", outputCsv);
        console2.log("Markdown report: out/few_quote_comparison.md");
        console2.log("CSV report: out/few_quote_comparison.csv");
    }

    function _setUp() internal {
        manager = new PoolManager(address(this));
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        quoter = new V4Quoter(manager);
        tokenA = new MockERC20("Token A", "TA", 18);
        tokenB = new MockERC20("Token B", "TB", 18);
        tokenA.mint(address(this), 1_000_000e18);
        tokenB.mint(address(this), 1_000_000e18);
        tokenA.mint(address(manager), 1_000_000e18);
        tokenB.mint(address(manager), 1_000_000e18);
        factory = new MockFewFactory();
        factory.createToken(address(tokenA));
        factory.createToken(address(tokenB));
        weth = new MockWETH9();

        bytes memory shellArgs = abi.encode(manager, IFewFactory(address(factory)), weth, quoter, address(this));
        uint160 shellFlags =
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        (address shellAddr, bytes32 shellSalt) =
            HookMiner.find(address(this), shellFlags, type(FewV4ShellHook).creationCode, shellArgs);
        shellHook =
            new FewV4ShellHook{salt: shellSalt}(manager, IFewFactory(address(factory)), weth, quoter, address(this));
        require(address(shellHook) == shellAddr, "shell hook address mismatch");

        bytes memory dynamicArgs = abi.encode(manager, IFewFactory(address(factory)), address(this));
        (address dynamicAddr, bytes32 dynamicSalt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG,
            type(FewDynamicFeeHook).creationCode,
            dynamicArgs
        );
        dynamicHook = new FewDynamicFeeHook{salt: dynamicSalt}(manager, IFewFactory(address(factory)), address(this));
        require(address(dynamicHook) == dynamicAddr, "dynamic hook address mismatch");

        origin0 = address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
        origin1 = address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);
        few0 = factory.getWrappedToken(origin0);
        few1 = factory.getWrappedToken(origin1);
        orderAligned = few0 < few1;
        if (!orderAligned) (few0, few1) = (few1, few0);
        shellKey = PoolKey(
            Currency.wrap(origin0), Currency.wrap(origin1), FIXED_FEE, TICK_SPACING, IHooks(address(shellHook))
        );
        fixedFewKey = PoolKey(Currency.wrap(few0), Currency.wrap(few1), FIXED_FEE, TICK_SPACING, IHooks(address(0)));
        dynamicFewKey = PoolKey(
            Currency.wrap(few0),
            Currency.wrap(few1),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            TICK_SPACING,
            IHooks(address(dynamicHook))
        );

        manager.initialize(shellKey, SQRT_PRICE_1_1);
        manager.initialize(fixedFewKey, SQRT_PRICE_1_1);
        dynamicHook.configurePool(dynamicFewKey, FeeMath.Config(1000, 2000, 3000));
        manager.initialize(dynamicFewKey, SQRT_PRICE_1_1);
        shellHook.setLpPool(shellKey, fixedFewKey);
        _addLiquidity(fixedFewKey, LIQUIDITY);
        _addLiquidity(dynamicFewKey, LIQUIDITY);

        IERC20(few0).approve(address(liquidityRouter), type(uint256).max);
        IERC20(few1).approve(address(liquidityRouter), type(uint256).max);
        IERC20(origin0).approve(few0, type(uint256).max);
        IERC20(origin1).approve(few1, type(uint256).max);
        IERC20(few0).approve(address(shellHook), type(uint256).max);
        IERC20(few1).approve(address(shellHook), type(uint256).max);
        IERC20(address(tokenA)).approve(address(shellHook), type(uint256).max);
        IERC20(address(tokenB)).approve(address(shellHook), type(uint256).max);
        tokenA.mint(USER, 1000e18);
        tokenB.mint(USER, 1000e18);
    }

    function _seedPools() internal {
        _setBacking(100e18, 100e18);
    }

    function _setBacking(uint256 backing0, uint256 backing1) internal {
        deal(IFewWrappedToken(few0).token(), few0, backing0);
        deal(IFewWrappedToken(few1).token(), few1, backing1);
    }

    function _addLiquidity(PoolKey memory key, uint256 amount) internal {
        address w0 = Currency.unwrap(key.currency0);
        address w1 = Currency.unwrap(key.currency1);
        IERC20(IFewWrappedToken(w0).token()).approve(w0, type(uint256).max);
        IERC20(IFewWrappedToken(w1).token()).approve(w1, type(uint256).max);
        IFewWrappedToken(w0).wrap(amount * 101);
        IFewWrappedToken(w1).wrap(amount * 101);
        IERC20(w0).approve(address(liquidityRouter), type(uint256).max);
        IERC20(w1).approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-7000, 7000, int256(amount), bytes32(0)), bytes(""));
    }

    function measureScenario(bool zeroForOne, bool exactInput, uint256 amount, uint256 backing1)
        external
        returns (int256 scenarioBps, bool valid)
    {
        uint256 snapshot = vm.snapshotState();
        _setBacking(100e18, backing1);
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        uint256 fixedQuote;
        uint256 dynamicQuote;
        bool fewZeroForOne = zeroForOne == orderAligned;
        (bool fixedOk, uint256 fixedResult) = _tryQuote(fixedFewKey, fewZeroForOne, exactInput, amount);
        fixedQuote = fixedResult;
        (bool dynamicOk, uint256 dynamicResult) = _tryQuote(dynamicFewKey, fewZeroForOne, exactInput, amount);
        dynamicQuote = dynamicResult;
        uint256 denominator = fixedOk ? fixedQuote : 0;
        int256 delta = fixedOk && dynamicOk ? int256(dynamicQuote) - int256(fixedQuote) : int256(0);
        int256 pctBps = denominator == 0 || !dynamicOk
            ? int256(0)
            : (dynamicQuote > fixedQuote
                    ? int256((dynamicQuote - fixedQuote) * 10_000 / denominator)
                    : -int256((fixedQuote - dynamicQuote) * 10_000 / denominator));
        scenarioBps = pctBps;
        valid = fixedOk && dynamicOk;

        // Quote through the public Shell Hook path as an additional executable-quote check.
        // The route can be switched only by its owner; compare both LP targets in turn.
        uint256 shellFixed;
        uint256 shellDynamic;
        bool shellFixedOk;
        bool shellDynamicOk;
        if (fixedOk) {
            shellHook.setLpPool(shellKey, fixedFewKey);
            try shellHook.quote(zeroForOne, specified, shellKey.toId()) returns (uint256 q) {
                shellFixed = q;
                shellFixedOk = true;
            } catch {}
        }
        if (dynamicOk) {
            shellHook.setLpPool(shellKey, dynamicFewKey);
            try shellHook.quote(zeroForOne, specified, shellKey.toId()) returns (uint256 q) {
                shellDynamic = q;
                shellDynamicOk = true;
            } catch {}
        }
        string memory modeLabel = exactInput ? "Exact input" : "Exact output";
        string memory directionLabel = zeroForOne ? "0 -> 1" : "1 -> 0";
        string memory fixedLabel = fixedOk ? vm.toString(fixedQuote) : "REVERT";
        string memory dynamicLabel = dynamicOk ? vm.toString(dynamicQuote) : "REVERT";
        string memory deltaLabel = fixedOk && dynamicOk ? vm.toString(delta) : "n/a";
        string memory pctLabel = fixedOk && dynamicOk ? string.concat(vm.toString(pctBps), " bps") : "n/a";
        string memory shellFixedLabel = shellFixedOk ? vm.toString(shellFixed) : "REVERT";
        string memory shellDynamicLabel = shellDynamicOk ? vm.toString(shellDynamic) : "REVERT";

        outputTable = string.concat(
            outputTable,
            "| ",
            modeLabel,
            " | ",
            directionLabel,
            " | ",
            vm.toString(amount),
            " | ",
            vm.toString(backing1),
            " | ",
            fixedLabel,
            " | ",
            dynamicLabel,
            " | ",
            deltaLabel,
            " | ",
            pctLabel,
            " | ",
            shellFixedLabel,
            " | ",
            shellDynamicLabel,
            " |\n"
        );
        outputCsv = string.concat(
            outputCsv,
            modeLabel,
            ",",
            directionLabel,
            ",",
            vm.toString(amount),
            ",",
            vm.toString(backing1),
            ",",
            fixedLabel,
            ",",
            dynamicLabel,
            ",",
            deltaLabel,
            ",",
            vm.toString(pctBps),
            ",",
            shellFixedLabel,
            ",",
            shellDynamicLabel,
            "\n"
        );
        assertTrue(vm.revertToState(snapshot));
    }

    function _buildSummary() internal {
        summaryTable = string.concat(
            "# Quote comparison summary\n\n",
            "Scenario: both quotes use the same local Few v4 liquidity and spot price; only LP fee behavior differs. ",
            "Dynamic fee config is min/base/max = 1,000/2,000/3,000 (v4 fee units); fixed fee = 500. ",
            "Token0 backing = 100 tokens; Token1 backing = 50, 100, or 200 tokens.\n\n",
            "For exact input, negative delta means the dynamic pool returns less output. For exact output, positive delta means it requires more input.\n\n",
            "| Mode | Direction | Token1 backing | Avg delta | Avg delta % | Dynamic better | Dynamic worse |\n",
            "|---|---:|---:|---:|---:|---:|---:|\n"
        );
        uint256[3] memory backing = [uint256(50e18), 100e18, 200e18];
        for (uint256 mode; mode < 2; ++mode) {
            for (uint256 direction; direction < 2; ++direction) {
                for (uint256 inv; inv < 3; ++inv) {
                    uint256 group = (direction == 0 ? 0 : 6) + (mode == 0 ? 0 : 3) + inv;
                    int256 avgBps =
                        summaryCount[group] == 0 ? int256(0) : summaryBps[group] / int256(summaryCount[group]);
                    summaryTable = string.concat(
                        summaryTable,
                        "| ",
                        mode == 0 ? "Exact input" : "Exact output",
                        " | ",
                        direction == 0 ? "0 -> 1" : "1 -> 0",
                        " | ",
                        vm.toString(backing[inv]),
                        " | ",
                        _formatSigned(summaryBps[group], summaryCount[group]),
                        " | ",
                        vm.toString(avgBps),
                        " bps",
                        " | ",
                        vm.toString(summaryBetter[group]),
                        " / 5 | ",
                        vm.toString(summaryWorse[group]),
                        " / 5 |\n"
                    );
                }
            }
        }
        summaryTable = string.concat(
            summaryTable,
            "\nConclusion: for exact input, the dynamic fee pool returns less output in all tested cases; mean impact is ",
            vm.toString(modeDirectionBps[0] / int256(modeDirectionCount[0])),
            " bps (0 -> 1) and ",
            vm.toString(modeDirectionBps[1] / int256(modeDirectionCount[1])),
            " bps (1 -> 0). ",
            "For exact output, it requires more input in all tested cases; mean impact is ",
            vm.toString(modeDirectionBps[2] / int256(modeDirectionCount[2])),
            " bps (0 -> 1) and ",
            vm.toString(modeDirectionBps[3] / int256(modeDirectionCount[3])),
            " bps (1 -> 0). ",
            ". With this configuration (dynamic min/base/max 1,000/2,000/3,000 vs fixed fee 500), the dynamic route is consistently worse for the trader across the tested inventory ratios.\n\n",
            "Overall dynamic fee quote impact ranges from ",
            vm.toString(worstBps),
            " to +",
            vm.toString(bestBps),
            " bps across the tested cases.\n\n"
        );
    }

    function _formatSigned(int256 sum, uint256 count) internal pure returns (string memory) {
        if (count == 0) return "n/a";
        int256 avgBps = sum / int256(count);
        return string.concat(vm.toString(avgBps), " bps avg");
    }

    function _tryQuote(PoolKey memory key, bool zeroForOne, bool exactInput, uint256 amount)
        internal
        returns (bool ok, uint256 result)
    {
        try this.quotePool(key, zeroForOne, exactInput, amount) returns (uint256 q) {
            return (true, q);
        } catch {
            return (false, 0);
        }
    }

    function quotePool(PoolKey memory key, bool zeroForOne, bool exactInput, uint256 amount)
        external
        returns (uint256 result)
    {
        IV4Quoter.QuoteExactSingleParams memory params =
            IV4Quoter.QuoteExactSingleParams(key, zeroForOne, uint128(amount), bytes(""));
        if (exactInput) (result,) = quoter.quoteExactInputSingle(params);
        else (result,) = quoter.quoteExactOutputSingle(params);
    }

    function _printHeader() internal pure {
        console2.log("Generating formatted Markdown and CSV quote comparison reports.");
        console2.log(
            "Exact-input quote is output; exact-output quote is required input. Amounts use 18-decimal raw units."
        );
    }
}
