// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {FewV4ShellHook} from "../../src/FewV4ShellHook.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";

contract ShellTestToken {
    string public constant name = "Shell Test Token";
    string public constant symbol = "SHELL";
    uint8 public constant decimals = 18;

    bool public initialized;
    address public underlying;
    uint256 public totalSupply;
    address public callbackTarget;
    bytes public callbackData;
    bool public badWrapReturn;
    bool public badUnwrapReturn;
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    function initialize(address _underlying) external {
        require(!initialized, "already initialized");
        initialized = true;
        underlying = _underlying;
    }

    function token() external view returns (address) {
        return underlying;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function configureCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function configureBadReturns(bool wrapReturn, bool unwrapReturn) external {
        badWrapReturn = wrapReturn;
        badUnwrapReturn = unwrapReturn;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            uint256 approved = allowance[from][msg.sender];
            if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function wrap(uint256 amount) external returns (uint256) {
        require(underlying != address(0), "not wrapper");
        ShellTestToken(underlying).transferFrom(msg.sender, address(this), amount);
        _runCallback();
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        return badWrapReturn ? amount - 1 : amount;
    }

    function unwrap(uint256 amount) external returns (uint256) {
        require(underlying != address(0), "not wrapper");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        ShellTestToken(underlying).transfer(msg.sender, amount);
        _runCallback();
        return badUnwrapReturn ? amount - 1 : amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _runCallback() internal {
        if (callbackTarget == address(0)) return;
        (bool success, bytes memory reason) = callbackTarget.call(callbackData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}

contract ShellTestFactory is IFewFactory {
    mapping(address origin => address wrapper) public wrappers;

    function setWrappedToken(address origin, address wrapper) external {
        wrappers[origin] = wrapper;
    }

    function getWrappedToken(address origin) external view returns (address wrappedToken) {
        return wrappers[origin];
    }
}

abstract contract FewV4ShellHookIntegrationBase is Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint24 internal constant FEE = 500;
    int24 internal constant TICK_SPACING = 10;
    uint256 internal constant USER_SUPPLY = 1e30;
    uint256 internal constant WRAP_AMOUNT = 1e27;
    int256 internal constant TEST_LIQUIDITY = 1e24;
    uint256 internal constant EXACT_INPUT = 1e18;
    uint256 internal constant EXACT_OUTPUT = 8e17;

    ShellTestToken internal token0;
    ShellTestToken internal token1;
    ShellTestToken internal few0;
    ShellTestToken internal few1;
    ShellTestFactory internal factory;
    V4Quoter internal shellQuoter;
    FewV4ShellHook internal hook;

    PoolKey internal innerKey;
    PoolKey internal outerKey;
    PoolKey internal wrapperKey0;
    PoolKey internal wrapperKey1;
    PoolId internal innerPoolId;
    PoolId internal outerPoolId;

    function reversedOrder() internal pure virtual returns (bool);

    function setUp() public virtual {
        deployFreshManagerAndRouters();

        token0 = _installToken(address(0x1000), address(0));
        token1 = _installToken(address(0x2000), address(0));
        few0 = _installToken(reversedOrder() ? address(0x4000) : address(0x3000), address(token0));
        few1 = _installToken(reversedOrder() ? address(0x3000) : address(0x4000), address(token1));

        token0.mint(address(this), USER_SUPPLY);
        token1.mint(address(this), USER_SUPPLY);
        token0.approve(address(few0), type(uint256).max);
        token1.approve(address(few1), type(uint256).max);
        few0.wrap(WRAP_AMOUNT);
        few1.wrap(WRAP_AMOUNT);

        _approveRouters(token0);
        _approveRouters(token1);
        _approveRouters(few0);
        _approveRouters(few1);

        innerKey = _poolKey(address(few0), address(few1), IHooks(address(0)));
        innerPoolId = innerKey.toId();
        manager.initialize(innerKey, SQRT_PRICE_1_1);
        _addLiquidity(innerKey);

        // These two pools model the already-deployed origin/FewToken 1:1 LPs. The shell never
        // calls them, but their singleton inventory supplies the atomic origin-token flash leg.
        wrapperKey0 = _poolKey(address(token0), address(few0), IHooks(address(0)));
        wrapperKey1 = _poolKey(address(token1), address(few1), IHooks(address(0)));
        manager.initialize(wrapperKey0, SQRT_PRICE_1_1);
        manager.initialize(wrapperKey1, SQRT_PRICE_1_1);
        _addLiquidity(wrapperKey0);
        _addLiquidity(wrapperKey1);

        factory = new ShellTestFactory();
        factory.setWrappedToken(address(token0), address(few0));
        factory.setWrappedToken(address(token1), address(few1));
        shellQuoter = new V4Quoter(manager);

        PoolId[] memory allowedInnerPools = new PoolId[](1);
        allowedInnerPools[0] = innerPoolId;
        uint160 flags = _hookFlags();
        bytes memory constructorArgs =
            abi.encode(manager, IFewFactory(address(factory)), IV4Quoter(address(shellQuoter)), allowedInnerPools);
        (address mined, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FewV4ShellHook).creationCode, constructorArgs);
        hook = new FewV4ShellHook{salt: salt}(
            manager, IFewFactory(address(factory)), IV4Quoter(address(shellQuoter)), allowedInnerPools
        );
        assertEq(address(hook), mined, "mined hook address");
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, flags, "hook permission mask");

        outerKey = _poolKey(address(token0), address(token1), IHooks(address(hook)));
        outerPoolId = outerKey.toId();
        (,,,, uint160 recommendedPrice) = hook.previewRoute(address(token0), address(token1), FEE, TICK_SPACING);
        manager.initialize(outerKey, recommendedPrice);
    }

    function test_exactInput_zeroForOne_quoteMatchesInnerAndExecution() public {
        _assertExactInput(true);
    }

    function test_exactInput_oneForZero_quoteMatchesInnerAndExecution() public {
        _assertExactInput(false);
    }

    function test_exactOutput_zeroForOne_quoteMatchesInnerAndExecution() public {
        _assertExactOutput(true);
    }

    function test_exactOutput_oneForZero_quoteMatchesInnerAndExecution() public {
        _assertExactOutput(false);
    }

    function test_routeIsHooklessAllowlistedStaticAndImmutableFromFactory() public {
        FewV4ShellHook.RegisteredRoute memory route = hook.routeForPool(outerPoolId);
        assertTrue(route.registered);
        assertEq(PoolId.unwrap(route.innerPoolId), PoolId.unwrap(innerPoolId));
        assertEq(route.orderAligned, !reversedOrder());
        assertEq(route.fee, FEE);
        assertEq(route.tickSpacing, TICK_SPACING);
        assertTrue(hook.allowedInnerPools(innerPoolId));

        PoolKey memory registeredInner = hook.innerPoolKey(outerPoolId);
        assertEq(address(registeredInner.hooks), address(0));
        assertEq(PoolId.unwrap(registeredInner.toId()), PoolId.unwrap(innerPoolId));

        ShellTestToken rogue = _installToken(address(0x5000), address(token0));
        factory.setWrappedToken(address(token0), address(rogue));
        _assertExactInput(true);
    }

    function test_outerLiquidityDonationAndNonemptyHookDataAreRejected() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            outerKey, ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}), bytes("")
        );

        vm.expectRevert();
        donateRouter.donate(outerKey, 1, 1, bytes(""));

        vm.expectRevert();
        swap(outerKey, true, -int256(EXACT_INPUT), hex"01");
    }

    function test_nonExtremeOuterPriceLimitIsRejectedBeforeInnerStateChanges() public {
        (uint160 innerPriceBefore,,,) = manager.getSlot0(innerPoolId);
        vm.expectRevert();
        swapRouter.swap(
            outerKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(EXACT_INPUT), sqrtPriceLimitX96: SQRT_PRICE_1_2}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        (uint160 innerPriceAfter,,,) = manager.getSlot0(innerPoolId);
        assertEq(innerPriceAfter, innerPriceBefore);
    }

    function test_insufficientPoolManagerOriginInventoryRevertsAtomicallyThenRecovers() public {
        address input = address(token0);
        uint256 inventoryBefore = ShellTestToken(input).balanceOf(address(manager));
        (uint160 innerPriceBefore,,,) = manager.getSlot0(innerPoolId);

        deal(input, address(manager), EXACT_INPUT - 1);
        vm.expectRevert();
        swap(outerKey, true, -int256(EXACT_INPUT), bytes(""));
        (uint160 innerPriceAfterRevert,,,) = manager.getSlot0(innerPoolId);
        assertEq(innerPriceAfterRevert, innerPriceBefore);

        deal(input, address(manager), inventoryBefore);
        _assertExactInput(true);
    }

    function test_quoteRejectsInsufficientPoolManagerOriginInventoryWithoutMutation() public {
        address input = address(token0);
        uint256 inventoryBefore = ShellTestToken(input).balanceOf(address(manager));
        deal(input, address(manager), EXACT_INPUT - 1);
        _Snapshot memory lowInventoryState = _snapshot();

        vm.expectRevert();
        hook.quote(true, -int256(EXACT_INPUT), outerPoolId);

        _assertQuoteDidNotMutate(lowInventoryState);
        deal(input, address(manager), inventoryBefore);
    }

    function test_initializeRejectsWrongOuterPriceAndDuplicateInnerRegistration() public {
        (uint160 expectedPrice,,,) = manager.getSlot0(outerPoolId);
        uint160 wrongPrice = expectedPrice + 1;
        vm.expectRevert(
            _wrappedBeforeInitializeError(
                abi.encodeWithSelector(FewV4ShellHook.OuterPriceMismatch.selector, wrongPrice, expectedPrice)
            )
        );
        manager.initialize(outerKey, wrongPrice);

        vm.expectRevert(
            _wrappedBeforeInitializeError(
                abi.encodeWithSelector(FewV4ShellHook.InnerPoolAlreadyRegistered.selector, innerPoolId, outerPoolId)
            )
        );
        manager.initialize(outerKey, expectedPrice);
    }

    function test_constructorRejectsDuplicateInnerAllowlist() public {
        PoolId[] memory duplicateAllowlist = new PoolId[](2);
        duplicateAllowlist[0] = innerPoolId;
        duplicateAllowlist[1] = innerPoolId;
        bytes memory constructorArgs =
            abi.encode(manager, IFewFactory(address(factory)), IV4Quoter(address(shellQuoter)), duplicateAllowlist);
        (, bytes32 salt) =
            HookMiner.find(address(this), _hookFlags(), type(FewV4ShellHook).creationCode, constructorArgs);

        vm.expectRevert(abi.encodeWithSelector(FewV4ShellHook.DuplicateAllowedInnerPool.selector, innerPoolId));
        new FewV4ShellHook{salt: salt}(
            manager, IFewFactory(address(factory)), IV4Quoter(address(shellQuoter)), duplicateAllowlist
        );
    }

    function test_constructorRejectsQuoterForDifferentPoolManager() public {
        PoolManager otherManager = new PoolManager(address(this));
        V4Quoter wrongQuoter = new V4Quoter(otherManager);
        PoolId[] memory allowedInnerPools = new PoolId[](1);
        allowedInnerPools[0] = innerPoolId;
        bytes memory constructorArgs =
            abi.encode(manager, IFewFactory(address(factory)), IV4Quoter(address(wrongQuoter)), allowedInnerPools);
        (, bytes32 salt) =
            HookMiner.find(address(this), _hookFlags(), type(FewV4ShellHook).creationCode, constructorArgs);

        vm.expectRevert(FewV4ShellHook.QuoterPoolManagerMismatch.selector);
        new FewV4ShellHook{salt: salt}(
            manager, IFewFactory(address(factory)), IV4Quoter(address(wrongQuoter)), allowedInnerPools
        );
    }

    function test_largeExactInputPartialFillRevertsAndRollsBackInnerPool() public {
        uint256 tooLarge = 1e26;
        address input = address(token0);
        uint256 inventoryBefore = ShellTestToken(input).balanceOf(address(manager));
        deal(input, address(manager), tooLarge);
        (uint160 innerPriceBefore,,,) = manager.getSlot0(innerPoolId);

        vm.expectRevert();
        swap(outerKey, true, -int256(tooLarge), bytes(""));

        (uint160 innerPriceAfter,,,) = manager.getSlot0(innerPoolId);
        assertEq(innerPriceAfter, innerPriceBefore);
        deal(input, address(manager), inventoryBefore);
    }

    function test_largeExactOutputPartialFillRevertsAndRollsBackInnerPool() public {
        uint256 tooLarge = 1e26;
        (uint160 innerPriceBefore,,,) = manager.getSlot0(innerPoolId);

        vm.expectRevert();
        swap(outerKey, true, int256(tooLarge), bytes(""));

        (uint160 innerPriceAfter,,,) = manager.getSlot0(innerPoolId);
        assertEq(innerPriceAfter, innerPriceBefore);
    }

    function test_reentrantWrapperCannotEnterAnotherOuterSwap() public {
        SwapParams memory reentrantParams = SwapParams({
            zeroForOne: true, amountSpecified: -int256(EXACT_INPUT), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        few0.configureCallback(
            address(manager), abi.encodeCall(IPoolManager.swap, (outerKey, reentrantParams, bytes("")))
        );
        _Snapshot memory beforeState = _snapshot();

        vm.expectRevert();
        swap(outerKey, true, -int256(EXACT_INPUT), bytes(""));

        _assertQuoteDidNotMutate(beforeState);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(few0.balanceOf(address(hook)), 0);
    }

    function test_wrapperFalseReturnValuesRevertAtomically() public {
        _Snapshot memory beforeState = _snapshot();
        few0.configureBadReturns(true, false);
        vm.expectRevert();
        swap(outerKey, true, -int256(EXACT_INPUT), bytes(""));
        _assertQuoteDidNotMutate(beforeState);

        few0.configureBadReturns(false, false);
        few1.configureBadReturns(false, true);
        vm.expectRevert();
        swap(outerKey, true, -int256(EXACT_INPUT), bytes(""));
        _assertQuoteDidNotMutate(beforeState);
    }

    function test_previewRejectsNativeDynamicAndNonAllowlistedInnerKeys() public {
        vm.expectRevert(FewV4ShellHook.NativeCurrencyNotSupported.selector);
        hook.previewRoute(address(0), address(token1), FEE, TICK_SPACING);

        vm.expectRevert(FewV4ShellHook.DynamicFeeNotSupported.selector);
        hook.previewRoute(address(token0), address(token1), 0x800000, TICK_SPACING);

        vm.expectRevert();
        hook.previewRoute(address(token0), address(token1), 3000, 60);
    }

    function test_pseudoTvlIsDepthProxyAndInventoryIsWrapperPoolBacked() public {
        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(outerPoolId);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertGt(hook.availableSettlementInventory(outerPoolId, true), EXACT_INPUT);
        assertGt(hook.availableSettlementInventory(outerPoolId, false), EXACT_INPUT);
    }

    function _assertExactInput(bool zeroForOne) internal {
        _Snapshot memory beforeState = _snapshot();
        uint256 directQuote = _directQuote(zeroForOne, -int256(EXACT_INPUT));
        uint256 shellQuote = hook.quote(zeroForOne, -int256(EXACT_INPUT), outerPoolId);
        assertEq(shellQuote, directQuote, "outer and direct inner quote");
        _assertQuoteDidNotMutate(beforeState);

        ShellTestToken input = zeroForOne ? token0 : token1;
        ShellTestToken output = zeroForOne ? token1 : token0;
        uint256 userInputBefore = input.balanceOf(address(this));
        uint256 userOutputBefore = output.balanceOf(address(this));
        BalanceDelta delta = swap(outerKey, zeroForOne, -int256(EXACT_INPUT), bytes(""));

        assertEq(userInputBefore - input.balanceOf(address(this)), EXACT_INPUT);
        assertEq(output.balanceOf(address(this)) - userOutputBefore, shellQuote);
        assertEq(int256(zeroForOne ? delta.amount0() : delta.amount1()), -int256(EXACT_INPUT));
        assertEq(int256(zeroForOne ? delta.amount1() : delta.amount0()), int256(shellQuote));
        _assertPostSwap(beforeState);
    }

    function _assertExactOutput(bool zeroForOne) internal {
        _Snapshot memory beforeState = _snapshot();
        uint256 directQuote = _directQuote(zeroForOne, int256(EXACT_OUTPUT));
        uint256 shellQuote = hook.quote(zeroForOne, int256(EXACT_OUTPUT), outerPoolId);
        assertEq(shellQuote, directQuote, "outer and direct inner quote");
        _assertQuoteDidNotMutate(beforeState);

        ShellTestToken input = zeroForOne ? token0 : token1;
        ShellTestToken output = zeroForOne ? token1 : token0;
        uint256 userInputBefore = input.balanceOf(address(this));
        uint256 userOutputBefore = output.balanceOf(address(this));
        BalanceDelta delta = swap(outerKey, zeroForOne, int256(EXACT_OUTPUT), bytes(""));

        assertEq(userInputBefore - input.balanceOf(address(this)), shellQuote);
        assertEq(output.balanceOf(address(this)) - userOutputBefore, EXACT_OUTPUT);
        assertEq(int256(zeroForOne ? delta.amount0() : delta.amount1()), -int256(shellQuote));
        assertEq(int256(zeroForOne ? delta.amount1() : delta.amount0()), int256(EXACT_OUTPUT));
        _assertPostSwap(beforeState);
    }

    function _directQuote(bool outerZeroForOne, int256 amountSpecified) internal returns (uint256 result) {
        bool innerZeroForOne = outerZeroForOne == !reversedOrder();
        uint128 exactAmount = uint128(amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified));
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: innerKey, zeroForOne: innerZeroForOne, exactAmount: exactAmount, hookData: bytes("")
        });
        if (amountSpecified < 0) {
            (result,) = shellQuoter.quoteExactInputSingle(params);
        } else {
            (result,) = shellQuoter.quoteExactOutputSingle(params);
        }
    }

    struct _Snapshot {
        uint160 outerPrice;
        uint160 innerPrice;
        uint160 wrapper0Price;
        uint160 wrapper1Price;
        uint128 outerLiquidity;
        uint128 wrapper0Liquidity;
        uint128 wrapper1Liquidity;
        uint256 managerToken0;
        uint256 managerToken1;
    }

    function _snapshot() internal view returns (_Snapshot memory state) {
        (state.outerPrice,,,) = manager.getSlot0(outerPoolId);
        (state.innerPrice,,,) = manager.getSlot0(innerPoolId);
        (state.wrapper0Price,,,) = manager.getSlot0(wrapperKey0.toId());
        (state.wrapper1Price,,,) = manager.getSlot0(wrapperKey1.toId());
        state.outerLiquidity = manager.getLiquidity(outerPoolId);
        state.wrapper0Liquidity = manager.getLiquidity(wrapperKey0.toId());
        state.wrapper1Liquidity = manager.getLiquidity(wrapperKey1.toId());
        state.managerToken0 = token0.balanceOf(address(manager));
        state.managerToken1 = token1.balanceOf(address(manager));
    }

    function _assertQuoteDidNotMutate(_Snapshot memory beforeState) internal view {
        _Snapshot memory afterQuote = _snapshot();
        assertEq(afterQuote.outerPrice, beforeState.outerPrice, "quote outer price");
        assertEq(afterQuote.innerPrice, beforeState.innerPrice, "quote inner price");
        assertEq(afterQuote.managerToken0, beforeState.managerToken0, "quote manager token0");
        assertEq(afterQuote.managerToken1, beforeState.managerToken1, "quote manager token1");
        _assertWrapperPoolsUnchanged(beforeState, afterQuote);
    }

    function _assertPostSwap(_Snapshot memory beforeState) internal view {
        _Snapshot memory afterState = _snapshot();
        assertEq(afterState.outerPrice, beforeState.outerPrice, "outer price must not move");
        assertEq(afterState.outerLiquidity, 0, "outer liquidity must remain zero");
        assertTrue(afterState.innerPrice != beforeState.innerPrice, "inner price must move");
        assertEq(afterState.managerToken0, beforeState.managerToken0, "manager token0 inventory restored");
        assertEq(afterState.managerToken1, beforeState.managerToken1, "manager token1 inventory restored");
        _assertWrapperPoolsUnchanged(beforeState, afterState);

        assertEq(token0.balanceOf(address(hook)), 0, "hook token0");
        assertEq(token1.balanceOf(address(hook)), 0, "hook token1");
        assertEq(few0.balanceOf(address(hook)), 0, "hook few0");
        assertEq(few1.balanceOf(address(hook)), 0, "hook few1");
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(token0))), 0, "delta token0");
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(token1))), 0, "delta token1");
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(few0))), 0, "delta few0");
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(few1))), 0, "delta few1");
        assertEq(manager.getNonzeroDeltaCount(), 0, "nonzero delta count");

        assertEq(token0.balanceOf(address(few0)), few0.totalSupply(), "few0 remains fully backed");
        assertEq(token1.balanceOf(address(few1)), few1.totalSupply(), "few1 remains fully backed");
    }

    function _assertWrapperPoolsUnchanged(_Snapshot memory beforeState, _Snapshot memory afterState) internal pure {
        assertEq(afterState.wrapper0Price, beforeState.wrapper0Price, "wrapper pool0 price");
        assertEq(afterState.wrapper1Price, beforeState.wrapper1Price, "wrapper pool1 price");
        assertEq(afterState.wrapper0Liquidity, beforeState.wrapper0Liquidity, "wrapper pool0 liquidity");
        assertEq(afterState.wrapper1Liquidity, beforeState.wrapper1Liquidity, "wrapper pool1 liquidity");
    }

    function _installToken(address target, address underlying) internal returns (ShellTestToken token) {
        ShellTestToken implementation = new ShellTestToken();
        vm.etch(target, address(implementation).code);
        token = ShellTestToken(target);
        token.initialize(underlying);
    }

    function _approveRouters(ShellTestToken token) internal {
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(donateRouter), type(uint256).max);
    }

    function _hookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
    }

    function _wrappedBeforeInitializeError(bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeInitialize.selector,
            reason,
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    function _poolKey(address a, address b, IHooks hooks) internal pure returns (PoolKey memory) {
        (address first, address second) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(first),
            currency1: Currency.wrap(second),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: hooks
        });
    }

    function _addLiquidity(PoolKey memory poolKey) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: TEST_LIQUIDITY, salt: 0}),
            bytes("")
        );
    }
}

contract FewV4ShellHookSameOrderIntegrationTest is FewV4ShellHookIntegrationBase {
    function reversedOrder() internal pure override returns (bool) {
        return false;
    }
}

contract FewV4ShellHookReversedOrderIntegrationTest is FewV4ShellHookIntegrationBase {
    function reversedOrder() internal pure override returns (bool) {
        return true;
    }
}
