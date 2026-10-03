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
import {FewV4NettingShellHook} from "../../src/experimental/FewV4NettingShellHook.sol";
import {IAggregatorHook} from "../../src/interfaces/IAggregatorHook.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";

interface INettingUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface INettingPermit2Allowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract LookalikeWrapper {
    address public immutable token;

    constructor(address underlying) {
        token = underlying;
    }
}

/// @notice Fixed-block comparison of immediate wrap/unwrap settlement and ERC-6909 inventory netting.
/// @dev The fork never broadcasts a transaction or modifies mainnet state.
contract FewV4NettingShellHookForkTest is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 26_069_215;
    uint256 internal constant FEW_POSITION_ID = 416_852;

    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant FEW_FACTORY = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant USER = address(0xBEEFCAFE);
    address internal constant RECIPIENT = address(0xCAFE);

    uint128[3] internal wethAmounts = [uint128(0.001 ether), uint128(0.01 ether), uint128(0.05 ether)];
    uint128[3] internal wbtcAmounts = [uint128(10_000), uint128(100_000), uint128(500_000)];

    bool internal forked;
    IPoolManager internal manager;
    FewV4ShellHook internal immediateHook;
    FewV4NettingShellHook internal nettingHook;
    PoolKey internal fewKey;
    PoolKey internal immediateShellKey;
    PoolKey internal nettingShellKey;
    PoolKey internal immediateEthShellKey;
    PoolKey internal nettingEthShellKey;
    address internal fewWeth;
    address internal fewWbtc;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
        forked = true;

        manager = IPoolManager(V4_POOL_MANAGER);
        (fewKey,) = IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(FEW_POSITION_ID);
        fewWeth = IFewFactory(FEW_FACTORY).getWrappedToken(WETH);
        fewWbtc = IFewFactory(FEW_FACTORY).getWrappedToken(WBTC);
        assertTrue(fewWeth != address(0) && fewWbtc != address(0));

        V4Quoter quoter = new V4Quoter(manager);
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory immediateArgs =
            abi.encode(manager, IFewFactory(FEW_FACTORY), IWETH9(WETH), IV4Quoter(address(quoter)), address(this));
        (, bytes32 immediateSalt) =
            HookMiner.find(address(this), flags, type(FewV4ShellHook).creationCode, immediateArgs);
        immediateHook = new FewV4ShellHook{salt: immediateSalt}(
            manager, IFewFactory(FEW_FACTORY), IWETH9(WETH), IV4Quoter(address(quoter)), address(this)
        );

        bytes memory nettingArgs =
            abi.encode(manager, IFewFactory(FEW_FACTORY), IWETH9(WETH), IV4Quoter(address(quoter)), address(this));
        (, bytes32 nettingSalt) =
            HookMiner.find(address(this), flags, type(FewV4NettingShellHook).creationCode, nettingArgs);
        nettingHook = new FewV4NettingShellHook{salt: nettingSalt}(
            manager, IFewFactory(FEW_FACTORY), IWETH9(WETH), IV4Quoter(address(quoter)), address(this)
        );

        immediateShellKey = _shellKey(IHooks(address(immediateHook)));
        nettingShellKey = _shellKey(IHooks(address(nettingHook)));
        immediateEthShellKey = _ethShellKey(IHooks(address(immediateHook)));
        nettingEthShellKey = _ethShellKey(IHooks(address(nettingHook)));
        (uint160 fewPrice,,,) = manager.getSlot0(fewKey.toId());
        manager.initialize(immediateShellKey, _mappedShellPrice(immediateShellKey, fewPrice));
        manager.initialize(nettingShellKey, _mappedShellPrice(nettingShellKey, fewPrice));
        manager.initialize(immediateEthShellKey, _mappedShellPrice(immediateEthShellKey, fewPrice));
        manager.initialize(nettingEthShellKey, _mappedShellPrice(nettingEthShellKey, fewPrice));
        immediateHook.setLpPool(immediateShellKey, fewKey);
        nettingHook.setLpPool(nettingShellKey, fewKey);
        immediateHook.setLpPool(immediateEthShellKey, fewKey);
        nettingHook.setLpPool(nettingEthShellKey, fewKey);

        _fundNettingClaims();
        _prepareUser();
    }

    modifier requireFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_quoteExecutionAndGasMatrix_bothPoolsDirectionsAndTradeTypes() public requireFork {
        _runGasMatrix(immediateShellKey, nettingShellKey);
        _runGasMatrix(immediateEthShellKey, nettingEthShellKey);
    }

    function test_fourTradeBatchRebalance_restoresAllClaims() public requireFork {
        uint256 originWethBefore = nettingHook.claimBalance(Currency.wrap(WETH));
        uint256 originWbtcBefore = nettingHook.claimBalance(Currency.wrap(WBTC));
        uint256 fewWethBefore = nettingHook.claimBalance(Currency.wrap(fewWeth));
        uint256 fewWbtcBefore = nettingHook.claimBalance(Currency.wrap(fewWbtc));

        for (uint256 i; i < 4; ++i) {
            _executeAndMeasure(nettingShellKey, IAggregatorHook(address(nettingHook)), false, true, 0.001 ether);
        }

        uint256 accumulatedWeth = nettingHook.claimBalance(Currency.wrap(WETH)) - originWethBefore;
        uint256 accumulatedFewWbtc = nettingHook.claimBalance(Currency.wrap(fewWbtc)) - fewWbtcBefore;
        assertEq(fewWethBefore - nettingHook.claimBalance(Currency.wrap(fewWeth)), accumulatedWeth);
        assertEq(originWbtcBefore - nettingHook.claimBalance(Currency.wrap(WBTC)), accumulatedFewWbtc);

        nettingHook.rebalancePair(
            Currency.wrap(WETH), fewWeth, accumulatedWeth, Currency.wrap(WBTC), fewWbtc, accumulatedFewWbtc
        );

        assertEq(nettingHook.claimBalance(Currency.wrap(WETH)), originWethBefore);
        assertEq(nettingHook.claimBalance(Currency.wrap(WBTC)), originWbtcBefore);
        assertEq(nettingHook.claimBalance(Currency.wrap(fewWeth)), fewWethBefore);
        assertEq(nettingHook.claimBalance(Currency.wrap(fewWbtc)), fewWbtcBefore);
    }

    function test_claimShortfall_fallsBackToImmediateSettlement() public requireFork {
        uint256 available = nettingHook.claimBalance(Currency.wrap(fewWeth));
        nettingHook.withdrawClaim(Currency.wrap(fewWeth), address(this), available);

        uint256 userWbtcBefore = IERC20(WBTC).balanceOf(USER);
        uint256 userWethBefore = IERC20(WETH).balanceOf(USER);
        uint128 amount = uint128(0.001 ether);
        uint256 quote = immediateHook.quote(false, -int256(uint256(amount)), immediateShellKey.toId());
        bytes[] memory inputs = _routerInputs(nettingShellKey, false, true, amount, quote);

        vm.prank(USER);
        INettingUniversalRouter(UNIVERSAL_ROUTER).execute(hex"10", inputs, block.timestamp + 1);

        assertEq(IERC20(WETH).balanceOf(USER), userWethBefore - amount);
        assertEq(IERC20(WBTC).balanceOf(USER), userWbtcBefore + quote);
    }

    function test_fullyUnfundedHook_fallsBackToImmediateSettlement() public requireFork {
        _withdrawAllClaims();

        uint128 amount = uint128(0.001 ether);
        uint256 quote = immediateHook.quote(false, -int256(uint256(amount)), immediateShellKey.toId());
        bytes[] memory inputs = _routerInputs(nettingShellKey, false, true, amount, quote);

        uint256 userWbtcBefore = IERC20(WBTC).balanceOf(USER);
        uint256 userWethBefore = IERC20(WETH).balanceOf(USER);

        vm.prank(USER);
        INettingUniversalRouter(UNIVERSAL_ROUTER).execute(hex"10", inputs, block.timestamp + 1);

        assertEq(IERC20(WETH).balanceOf(USER), userWethBefore - amount);
        assertEq(IERC20(WBTC).balanceOf(USER), userWbtcBefore + quote);
    }

    function test_originOutputClaimShortfall_fallsBackToImmediateSettlement() public requireFork {
        uint256 available = nettingHook.claimBalance(Currency.wrap(WBTC));
        nettingHook.withdrawClaim(Currency.wrap(WBTC), address(this), available);

        uint128 amount = uint128(0.001 ether);
        uint256 quote = immediateHook.quote(false, -int256(uint256(amount)), immediateShellKey.toId());
        bytes[] memory inputs = _routerInputs(nettingShellKey, false, true, amount, quote);

        uint256 userWbtcBefore = IERC20(WBTC).balanceOf(USER);
        uint256 userWethBefore = IERC20(WETH).balanceOf(USER);

        vm.prank(USER);
        INettingUniversalRouter(UNIVERSAL_ROUTER).execute(hex"10", inputs, block.timestamp + 1);

        assertEq(IERC20(WETH).balanceOf(USER), userWethBefore - amount);
        assertEq(IERC20(WBTC).balanceOf(USER), userWbtcBefore + quote);
    }

    function test_ownerCanWithdrawErc20AndNativeClaims() public requireFork {
        uint256 wethClaimBefore = nettingHook.claimBalance(Currency.wrap(WETH));
        uint256 recipientWethBefore = IERC20(WETH).balanceOf(RECIPIENT);
        nettingHook.withdrawClaim(Currency.wrap(WETH), RECIPIENT, 1 ether);
        assertEq(nettingHook.claimBalance(Currency.wrap(WETH)), wethClaimBefore - 1 ether);
        assertEq(IERC20(WETH).balanceOf(RECIPIENT), recipientWethBefore + 1 ether);

        uint256 ethClaimBefore = nettingHook.claimBalance(Currency.wrap(address(0)));
        uint256 recipientEthBefore = RECIPIENT.balance;
        nettingHook.withdrawClaim(Currency.wrap(address(0)), RECIPIENT, 1 ether);
        assertEq(nettingHook.claimBalance(Currency.wrap(address(0))), ethClaimBefore - 1 ether);
        assertEq(RECIPIENT.balance, recipientEthBefore + 1 ether);
    }

    function test_nonOwnerCannotManageClaims() public requireFork {
        vm.startPrank(USER);
        vm.expectRevert();
        nettingHook.depositClaim{value: 1}(Currency.wrap(address(0)), 1);
        vm.expectRevert();
        nettingHook.withdrawClaim(Currency.wrap(WETH), USER, 1);
        vm.expectRevert();
        nettingHook.rebalanceOriginToFew(Currency.wrap(WETH), fewWeth, 1);
        vm.stopPrank();
    }

    function test_setLpPoolRejectsNonCanonicalWrappers() public requireFork {
        LookalikeWrapper fakeWeth = new LookalikeWrapper(WETH);
        LookalikeWrapper fakeWbtc = new LookalikeWrapper(WBTC);
        (address first, address second) = address(fakeWeth) < address(fakeWbtc)
            ? (address(fakeWeth), address(fakeWbtc))
            : (address(fakeWbtc), address(fakeWeth));
        PoolKey memory fakeKey = PoolKey({
            currency0: Currency.wrap(first),
            currency1: Currency.wrap(second),
            fee: fewKey.fee,
            tickSpacing: fewKey.tickSpacing,
            hooks: IHooks(address(0))
        });

        address rejectedUnderlying = LookalikeWrapper(first).token();
        address canonical = IFewFactory(FEW_FACTORY).getWrappedToken(rejectedUnderlying);
        vm.expectRevert(
            abi.encodeWithSelector(
                FewV4NettingShellHook.NonCanonicalWrapper.selector, first, rejectedUnderlying, canonical
            )
        );
        nettingHook.setLpPool(nettingShellKey, fakeKey);
    }

    function test_unlockCallbackRejectsExternalCaller() public requireFork {
        vm.expectRevert(FewV4NettingShellHook.InvalidClaimRequest.selector);
        nettingHook.unlockCallback(bytes("not an active request"));
    }

    function test_standaloneWethWbtcCombinedRebalanceGas() public requireFork {
        nettingHook.rebalancePair(Currency.wrap(WETH), fewWeth, 0.001 ether, Currency.wrap(WBTC), fewWbtc, 10_000);
        emit log_named_uint("WETH/WBTC combined rebalance gas", vm.lastCallGas().gasTotalUsed);
    }

    function test_standaloneEthWbtcCombinedRebalanceGas() public requireFork {
        nettingHook.rebalancePair(Currency.wrap(address(0)), fewWeth, 0.001 ether, Currency.wrap(WBTC), fewWbtc, 10_000);
        emit log_named_uint("ETH/WBTC combined rebalance gas", vm.lastCallGas().gasTotalUsed);
    }

    function _runGasMatrix(PoolKey memory immediateKey, PoolKey memory nettingKey) private {
        for (uint256 direction; direction < 2; ++direction) {
            for (uint256 kind; kind < 2; ++kind) {
                for (uint256 size; size < 3; ++size) {
                    bool zeroForOne = direction == 0;
                    bool exactIn = kind == 0;
                    Currency specifiedCurrency = exactIn
                        ? (zeroForOne ? immediateKey.currency0 : immediateKey.currency1)
                        : (zeroForOne ? immediateKey.currency1 : immediateKey.currency0);
                    uint128 amount = specifiedCurrency.isAddressZero()
                        ? wethAmounts[size]
                        : (Currency.unwrap(specifiedCurrency) == WBTC ? wbtcAmounts[size] : wethAmounts[size]);

                    uint256 snapshot = vm.snapshotState();
                    (uint256 immediateGas, uint256 immediateQuote) = _executeAndMeasure(
                        immediateKey, IAggregatorHook(address(immediateHook)), zeroForOne, exactIn, amount
                    );
                    assertTrue(vm.revertToState(snapshot));
                    (uint256 nettingGas, uint256 nettingQuote) = _executeAndMeasure(
                        nettingKey, IAggregatorHook(address(nettingHook)), zeroForOne, exactIn, amount
                    );

                    assertEq(nettingQuote, immediateQuote, "same FewToken pool must quote identically");
                    assertLt(nettingGas, immediateGas, "netting swap must use less execution gas");
                    emit log_named_uint("immediate settlement gas", immediateGas);
                    emit log_named_uint("netting settlement gas", nettingGas);
                    emit log_named_uint("swap gas saved", immediateGas - nettingGas);
                    assertTrue(vm.revertToState(snapshot));
                }
            }
        }
    }

    function _fundNettingClaims() private {
        uint256 wethPerForm = 25 ether;
        uint256 wbtcPerForm = 2e8;
        vm.deal(address(this), wethPerForm);
        deal(WETH, address(this), wethPerForm * 2);
        deal(WBTC, address(this), wbtcPerForm * 2);

        IERC20(WETH).forceApprove(fewWeth, wethPerForm);
        IERC20(WBTC).forceApprove(fewWbtc, wbtcPerForm);
        assertEq(IFewWrappedToken(fewWeth).wrap(wethPerForm), wethPerForm);
        assertEq(IFewWrappedToken(fewWbtc).wrap(wbtcPerForm), wbtcPerForm);

        _depositClaim(Currency.wrap(WETH), wethPerForm);
        _depositClaim(Currency.wrap(WBTC), wbtcPerForm);
        _depositClaim(Currency.wrap(fewWeth), wethPerForm);
        _depositClaim(Currency.wrap(fewWbtc), wbtcPerForm);
        nettingHook.depositClaim{value: wethPerForm}(Currency.wrap(address(0)), wethPerForm);
    }

    function _depositClaim(Currency currency, uint256 amount) private {
        IERC20(Currency.unwrap(currency)).forceApprove(address(nettingHook), amount);
        nettingHook.depositClaim(currency, amount);
    }

    function _withdrawAllClaims() private {
        nettingHook.withdrawClaim(Currency.wrap(WETH), address(this), nettingHook.claimBalance(Currency.wrap(WETH)));
        nettingHook.withdrawClaim(Currency.wrap(WBTC), address(this), nettingHook.claimBalance(Currency.wrap(WBTC)));
        nettingHook.withdrawClaim(
            Currency.wrap(fewWeth), address(this), nettingHook.claimBalance(Currency.wrap(fewWeth))
        );
        nettingHook.withdrawClaim(
            Currency.wrap(fewWbtc), address(this), nettingHook.claimBalance(Currency.wrap(fewWbtc))
        );
        nettingHook.withdrawClaim(
            Currency.wrap(address(0)), RECIPIENT, nettingHook.claimBalance(Currency.wrap(address(0)))
        );
    }

    function _prepareUser() private {
        vm.deal(USER, 100 ether);
        deal(WETH, USER, 100 ether);
        deal(WBTC, USER, 10e8);
        vm.startPrank(USER);
        IERC20(WETH).forceApprove(PERMIT2, type(uint256).max);
        IERC20(WBTC).forceApprove(PERMIT2, type(uint256).max);
        INettingPermit2Allowance(PERMIT2).approve(WETH, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        INettingPermit2Allowance(PERMIT2).approve(WBTC, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _executeAndMeasure(
        PoolKey memory key,
        IAggregatorHook aggregator,
        bool zeroForOne,
        bool exactIn,
        uint128 amount
    ) private returns (uint256 gasUsed, uint256 unspecified) {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        int256 specified = exactIn ? -int256(uint256(amount)) : int256(uint256(amount));
        unspecified = aggregator.quote(zeroForOne, specified, key.toId());
        uint256 maxOrExact = exactIn ? amount : unspecified;
        uint256 minOrExact = exactIn ? unspecified : amount;

        uint256 inputBefore = input.balanceOf(USER);
        uint256 outputBefore = output.balanceOf(USER);
        bytes[] memory inputs = _routerInputs(key, zeroForOne, exactIn, amount, unspecified);
        vm.prank(USER);
        INettingUniversalRouter(UNIVERSAL_ROUTER).execute{value: input.isAddressZero() ? maxOrExact : 0}(
            hex"10", inputs, block.timestamp + 1
        );
        gasUsed = vm.lastCallGas().gasTotalUsed;

        assertEq(inputBefore - input.balanceOf(USER), maxOrExact);
        assertEq(output.balanceOf(USER) - outputBefore, minOrExact);
    }

    function _routerInputs(PoolKey memory key, bool zeroForOne, bool exactIn, uint128 amount, uint256 unspecified)
        private
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

    function _shellKey(IHooks hook) private pure returns (PoolKey memory) {
        return
            PoolKey({
                currency0: Currency.wrap(WBTC), currency1: Currency.wrap(WETH), fee: 75, tickSpacing: 1, hooks: hook
            });
    }

    function _ethShellKey(IHooks hook) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), currency1: Currency.wrap(WBTC), fee: 75, tickSpacing: 1, hooks: hook
        });
    }

    function _mappedShellPrice(PoolKey memory shellKey, uint160 fewPrice) private view returns (uint160) {
        address shell0 = Currency.unwrap(shellKey.currency0);
        if (shell0 == address(0)) shell0 = WETH;
        address fewUnderlying0 = IFewWrappedToken(Currency.unwrap(fewKey.currency0)).token();
        return fewUnderlying0 == shell0 ? fewPrice : _invertPrice(fewPrice);
    }

    function _invertPrice(uint160 sqrtPriceX96) private pure returns (uint160) {
        return uint160((uint256(1) << 192) / sqrtPriceX96);
    }
}
