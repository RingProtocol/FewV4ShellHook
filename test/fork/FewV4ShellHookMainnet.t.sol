// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {FewV4ShellHook} from "../../src/FewV4ShellHook.sol";
import {IAggregatorHook} from "../../src/interfaces/IAggregatorHook.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2Allowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Fixed-block proof against Ethereum mainnet state. No transaction is broadcast.
contract FewV4ShellHookMainnetTest is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 26_069_215;
    uint256 internal constant FEW_POSITION_ID = 416_852;
    uint256 internal constant LIVE_ETH_SHELL_POSITION_ID = 416_064;

    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant FEW_FACTORY = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant LIVE_SHELL_HOOK = 0xADEf200B8E8b66e27D5bd11C87D789D4D6E82088;
    address internal constant USER = address(0xBEEFCAFE);

    uint128[3] internal ethAmounts = [uint128(0.001 ether), uint128(0.01 ether), uint128(0.05 ether)];
    uint128[3] internal wbtcAmounts = [uint128(10_000), uint128(100_000), uint128(500_000)];

    bool internal forked;
    IPoolManager internal manager;
    FewV4ShellHook internal candidate;
    PoolKey internal fewKey;
    PoolKey internal ethShellKey;
    PoolKey internal wethShellKey;
    PoolKey internal liveEthShellKey;
    uint256 internal readySnapshot;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, vm.envOr("TEST_FORK_BLOCK", FORK_BLOCK));
        forked = true;

        manager = IPoolManager(V4_POOL_MANAGER);
        (fewKey,) = IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(FEW_POSITION_ID);
        (liveEthShellKey,) = IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(LIVE_ETH_SHELL_POSITION_ID);
        assertEq(address(liveEthShellKey.hooks), LIVE_SHELL_HOOK);
        assertGt(manager.getLiquidity(fewKey.toId()), 0);

        V4Quoter quoter = new V4Quoter(manager);
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);
        bytes memory args =
            abi.encode(manager, IFewFactory(FEW_FACTORY), IWETH9(WETH), IV4Quoter(address(quoter)), address(this));
        (address expected, bytes32 salt) = HookMiner.find(address(this), flags, type(FewV4ShellHook).creationCode, args);
        candidate = new FewV4ShellHook{salt: salt}(
            manager, IFewFactory(FEW_FACTORY), IWETH9(WETH), IV4Quoter(address(quoter)), address(this)
        );
        assertEq(address(candidate), expected);

        ethShellKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(WBTC),
            fee: 75,
            tickSpacing: 1,
            hooks: IHooks(address(candidate))
        });
        wethShellKey = PoolKey({
            currency0: Currency.wrap(WBTC),
            currency1: Currency.wrap(WETH),
            fee: 75,
            tickSpacing: 1,
            hooks: IHooks(address(candidate))
        });

        (uint160 fewPrice,,,) = manager.getSlot0(fewKey.toId());
        manager.initialize(ethShellKey, _mappedShellPrice(ethShellKey, fewPrice));
        manager.initialize(wethShellKey, _mappedShellPrice(wethShellKey, fewPrice));
        candidate.setLpPool(ethShellKey, fewKey);
        candidate.setLpPool(wethShellKey, fewKey);

        vm.deal(USER, 100 ether);
        deal(WETH, USER, 100 ether);
        deal(WBTC, USER, 10e8);
        vm.startPrank(USER);
        IERC20(WETH).forceApprove(PERMIT2, type(uint256).max);
        IERC20(WBTC).forceApprove(PERMIT2, type(uint256).max);
        IPermit2Allowance(PERMIT2).approve(WETH, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        IPermit2Allowance(PERMIT2).approve(WBTC, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();

        readySnapshot = vm.snapshotState();
    }

    modifier requireFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_universalRouter_allEthAndWethModesAndSizes() public requireFork {
        _runMatrix(ethShellKey, IAggregatorHook(address(candidate)));
        _runMatrix(wethShellKey, IAggregatorHook(address(candidate)));
    }

    function test_universalRouter_gasVersusLiveShell() public requireFork {
        for (uint256 direction; direction < 2; ++direction) {
            for (uint256 kind; kind < 2; ++kind) {
                bool zeroForOne = direction == 0;
                bool exactIn = kind == 0;
                Currency input = zeroForOne ? liveEthShellKey.currency0 : liveEthShellKey.currency1;
                Currency output = zeroForOne ? liveEthShellKey.currency1 : liveEthShellKey.currency0;
                Currency specifiedCurrency = exactIn ? input : output;
                uint128 amount = Currency.unwrap(specifiedCurrency) == WBTC ? wbtcAmounts[1] : ethAmounts[1];

                uint256 snapshot = vm.snapshotState();
                uint256 liveGas =
                    _executeAndMeasure(liveEthShellKey, IAggregatorHook(LIVE_SHELL_HOOK), zeroForOne, exactIn, amount);
                assertTrue(vm.revertToState(snapshot));

                uint256 candidateGas =
                    _executeAndMeasure(ethShellKey, IAggregatorHook(address(candidate)), zeroForOne, exactIn, amount);
                emit log_named_uint("live Shell Universal Router gas", liveGas);
                emit log_named_uint("release candidate Universal Router gas", candidateGas);
                assertLt(candidateGas, liveGas);
                emit log_named_uint("saved gas", liveGas - candidateGas);
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }

    function test_failedSlippageRollsBackBalancesAndPoolPrice() public requireFork {
        (uint160 priceBefore,,,) = manager.getSlot0(fewKey.toId());
        uint256 userWbtcBefore = IERC20(WBTC).balanceOf(USER);
        uint256 userEthBefore = USER.balance;
        uint128 amountIn = ethAmounts[1];
        uint256 quoted = candidate.quote(true, -int256(uint256(amountIn)), ethShellKey.toId());

        bytes[] memory inputs = _routerInputs(ethShellKey, true, true, amountIn, quoted + 1);
        vm.prank(USER);
        vm.expectRevert();
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: amountIn}(hex"10", inputs, block.timestamp + 1);

        (uint160 priceAfter,,,) = manager.getSlot0(fewKey.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(IERC20(WBTC).balanceOf(USER), userWbtcBefore);
        assertEq(USER.balance, userEthBefore);
    }

    function _runMatrix(PoolKey memory key, IAggregatorHook aggregator) internal {
        for (uint256 direction; direction < 2; ++direction) {
            for (uint256 kind; kind < 2; ++kind) {
                for (uint256 size; size < 3; ++size) {
                    bool zeroForOne = direction == 0;
                    bool exactIn = kind == 0;
                    Currency input = zeroForOne ? key.currency0 : key.currency1;
                    Currency output = zeroForOne ? key.currency1 : key.currency0;
                    Currency specifiedCurrency = exactIn ? input : output;
                    uint128 amount = Currency.unwrap(specifiedCurrency) == WBTC ? wbtcAmounts[size] : ethAmounts[size];
                    _executeAndMeasure(key, aggregator, zeroForOne, exactIn, amount);
                    assertTrue(vm.revertToState(readySnapshot));
                }
            }
        }
    }

    function _executeAndMeasure(
        PoolKey memory key,
        IAggregatorHook aggregator,
        bool zeroForOne,
        bool exactIn,
        uint128 amount
    ) internal returns (uint256 gasUsed) {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        int256 specified = exactIn ? -int256(uint256(amount)) : int256(uint256(amount));
        uint256 unspecified = aggregator.quote(zeroForOne, specified, key.toId());
        uint256 maxOrExact = exactIn ? amount : unspecified;
        uint256 minOrExact = exactIn ? unspecified : amount;

        uint256 inputBefore = input.balanceOf(USER);
        uint256 outputBefore = output.balanceOf(USER);
        uint256 candidateFew0Before = IERC20(Currency.unwrap(fewKey.currency0)).balanceOf(address(candidate));
        uint256 candidateFew1Before = IERC20(Currency.unwrap(fewKey.currency1)).balanceOf(address(candidate));
        bytes[] memory inputs = _routerInputs(key, zeroForOne, exactIn, amount, unspecified);
        uint256 value = input.isAddressZero() ? maxOrExact : 0;

        vm.prank(USER);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: value}(hex"10", inputs, block.timestamp + 1);
        Vm.Gas memory measured = vm.lastCallGas();
        gasUsed = measured.gasTotalUsed;

        assertEq(inputBefore - input.balanceOf(USER), maxOrExact);
        assertEq(output.balanceOf(USER) - outputBefore, minOrExact);
        assertEq(IERC20(Currency.unwrap(fewKey.currency0)).balanceOf(address(candidate)), candidateFew0Before);
        assertEq(IERC20(Currency.unwrap(fewKey.currency1)).balanceOf(address(candidate)), candidateFew1Before);
    }

    function _routerInputs(PoolKey memory key, bool zeroForOne, bool exactIn, uint128 amount, uint256 unspecified)
        internal
        pure
        returns (bytes[] memory inputs)
    {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        bytes[] memory params = new bytes[](3);
        bytes memory actions;
        if (exactIn) {
            actions = hex"060c0f";
            params[0] = abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountIn: amount,
                    amountOutMinimum: uint128(unspecified),
                    hookData: bytes("")
                })
            );
            params[1] = abi.encode(Currency.unwrap(input), uint256(amount));
            params[2] = abi.encode(Currency.unwrap(output), unspecified);
        } else {
            actions = hex"080c0f";
            params[0] = abi.encode(
                IV4Router.ExactOutputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountOut: amount,
                    amountInMaximum: uint128(unspecified),
                    hookData: bytes("")
                })
            );
            params[1] = abi.encode(Currency.unwrap(input), unspecified);
            params[2] = abi.encode(Currency.unwrap(output), uint256(amount));
        }
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function _mappedShellPrice(PoolKey memory shellKey, uint160 fewPrice) internal view returns (uint160) {
        address shell0 = Currency.unwrap(shellKey.currency0);
        shell0 = shell0 == address(0) ? WETH : shell0;
        address fewUnderlying0 = IFewWrappedToken(Currency.unwrap(fewKey.currency0)).token();
        return shell0 == fewUnderlying0 ? fewPrice : _invertPrice(fewPrice);
    }

    function _invertPrice(uint160 sqrtPriceX96) internal pure returns (uint160) {
        return uint160((uint256(1) << 192) / sqrtPriceX96);
    }
}
