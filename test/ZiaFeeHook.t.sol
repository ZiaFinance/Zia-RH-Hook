// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Vm} from "forge-std/Vm.sol";

import {ZiaFeeHook} from "../src/ZiaFeeHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

contract ReentrantTreasury {
    ZiaFeeHook internal hook;
    Currency internal currency;

    bool public collectReentryBlocked;
    bool public callbackReentryBlocked;

    function configure(ZiaFeeHook hook_, Currency currency_) external {
        hook = hook_;
        currency = currency_;
    }

    receive() external payable {
        (bool collectOk,) = address(hook).call(abi.encodeCall(hook.collectFees, (currency)));
        collectReentryBlocked = !collectOk;

        (bool callbackOk,) = address(hook).call(abi.encodeCall(hook.unlockCallback, (abi.encode(currency, uint256(1)))));
        callbackReentryBlocked = !callbackOk;
    }
}

contract ZiaFeeHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant Q96 = 1 << 96;
    int24 internal constant TICK_SPACING = 60;
    address internal constant TREASURY = address(0xBEEF);
    address internal constant KEEPER = address(0xCAFE);
    bytes32 internal constant SWAP_EVENT_SIGNATURE =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    MockERC20 internal token0;
    MockERC20 internal token1;
    MockERC20 internal token2;
    ZiaFeeHook internal hook;
    PoolKey internal key;
    PoolKey internal secondKey;
    PoolId internal poolId;
    PoolId internal secondPoolId;

    receive() external payable {}

    function setUp() public {
        deployArtifactsAndLabel();

        token0 = new MockERC20("Token Zero", "TK0", 18);
        token1 = new MockERC20("Token One", "TK1", 18);
        token2 = new MockERC20("Token Two", "TK2", 18);
        token0.mint(address(this), 10_000_000 ether);
        token1.mint(address(this), 10_000_000 ether);
        token2.mint(address(this), 10_000_000 ether);

        hook = _deployHook(TREASURY, KEEPER, 0xA11CE);
        _approve(token0);
        _approve(token1);
        _approve(token2);

        key = _sortedKey(token0, token1, hook);
        poolId = key.toId();
        poolManager.initialize(key, Q96);
        _seed(key, 1_000 ether, 1_000 ether);

        secondKey = _sortedKey(token0, token2, hook);
        secondPoolId = secondKey.toId();
        poolManager.initialize(secondKey, Q96);
        _seed(secondKey, 1_000 ether, 1_000 ether);
    }

    function test_PermissionsAndAddressBitsMatchExactly() public view {
        uint160 expected = _requiredFlags();
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, expected);

        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_InitializationRecordsDefaults() public view {
        (uint24 lpFee, uint16 hookFeeBps, bool initialized) = hook.poolConfigs(poolId);
        assertEq(lpFee, 2_500);
        assertEq(hookFeeBps, 5);
        assertTrue(initialized);
    }

    function test_ConstructorRejectsZeroCriticalAddresses() public {
        vm.expectRevert(ZiaFeeHook.InvalidPoolManager.selector);
        deployCodeTo(
            "ZiaFeeHook.sol:ZiaFeeHook", abi.encode(IPoolManager(address(0)), TREASURY, KEEPER), _flagAddress(0xB001)
        );

        vm.expectRevert(ZiaFeeHook.InvalidTreasury.selector);
        deployCodeTo("ZiaFeeHook.sol:ZiaFeeHook", abi.encode(poolManager, address(0), KEEPER), _flagAddress(0xB002));

        vm.expectRevert(ZiaFeeHook.InvalidKeeper.selector);
        deployCodeTo("ZiaFeeHook.sol:ZiaFeeHook", abi.encode(poolManager, TREASURY, address(0)), _flagAddress(0xB003));
    }

    function test_StaticFeePoolReverts() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        PoolKey memory staticKey = _sortedKey(a, b, hook);
        staticKey.fee = 3_000;
        vm.expectRevert(); // PoolManager wraps the hook error.
        poolManager.initialize(staticKey, Q96);
    }

    function test_ExactInputZeroForOneFeeLandsInSpecifiedInputCurrency() public {
        _assertSpecifiedFee(key, true, true, 10 ether, 5);
    }

    function test_ExactInputOneForZeroFeeLandsInSpecifiedInputCurrency() public {
        _assertSpecifiedFee(key, false, true, 10 ether, 5);
    }

    function test_ExactOutputZeroForOneFeeLandsInSpecifiedOutputCurrency() public {
        _assertSpecifiedFee(key, true, false, 1 ether, 5);
    }

    function test_ExactOutputOneForZeroFeeLandsInSpecifiedOutputCurrency() public {
        _assertSpecifiedFee(key, false, false, 1 ether, 5);
    }

    function test_DustGuardBothSwapTypesAndDirections() public {
        for (uint256 exactInputRaw; exactInputRaw < 2; ++exactInputRaw) {
            bool exactInput = exactInputRaw == 1;
            for (uint256 direction; direction < 2; ++direction) {
                bool zeroForOne = direction == 1;
                Currency specified = _specifiedCurrency(key, zeroForOne, exactInput);
                uint256 beforeClaims = _claimBalance(address(hook), specified);
                exactInput ? _swapExactInput(key, zeroForOne, 1) : _swapExactOutput(key, zeroForOne, 1, 1 ether);
                assertEq(_claimBalance(address(hook), specified), beforeClaims);
            }
        }
    }

    function test_ZeroHookFeeIsNoOpBothSwapTypes() public {
        vm.prank(KEEPER);
        hook.setHookFee(poolId, 0);

        Currency exactInputCurrency = _specifiedCurrency(key, true, true);
        uint256 beforeInputClaims = _claimBalance(address(hook), exactInputCurrency);
        _swapExactInput(key, true, 10 ether);
        assertEq(_claimBalance(address(hook), exactInputCurrency), beforeInputClaims);

        Currency exactOutputCurrency = _specifiedCurrency(key, false, false);
        uint256 beforeOutputClaims = _claimBalance(address(hook), exactOutputCurrency);
        _swapExactOutput(key, false, 1 ether, 100 ether);
        assertEq(_claimBalance(address(hook), exactOutputCurrency), beforeOutputClaims);
    }

    function test_MaxHookFeeBothSwapTypes() public {
        vm.prank(KEEPER);
        hook.setHookFee(poolId, 25);
        _assertSpecifiedFee(key, true, true, 10 ether, 25);
        _assertSpecifiedFee(key, false, false, 1 ether, 25);
    }

    function test_LPFeeChangeAppliesOnNextSwapWithoutManagerSync() public {
        (,,, uint24 storedFeeBefore) = poolManager.getSlot0(poolId);
        assertEq(storedFeeBefore, 0);

        vm.prank(KEEPER);
        hook.setLpFee(poolId, 7_500);

        (,,, uint24 storedFeeAfterSetter) = poolManager.getSlot0(poolId);
        assertEq(storedFeeAfterSetter, 0);

        vm.recordLogs();
        _swapExactInput(key, true, 1 ether);
        assertEq(_swapFee(vm.getRecordedLogs()), 7_500);

        (,,, uint24 storedFeeAfterSwap) = poolManager.getSlot0(poolId);
        assertEq(storedFeeAfterSwap, 0);
    }

    function test_HookFeeChangeAppliesOnNextSwap() public {
        vm.prank(KEEPER);
        hook.setHookFee(poolId, 17);
        _assertSpecifiedFee(key, true, true, 10 ether, 17);
    }

    function test_MaxLPFeeIsAcceptedAsOverride() public {
        vm.prank(KEEPER);
        hook.setLpFee(poolId, 10_000);

        vm.recordLogs();
        _swapExactInput(key, false, 1 ether);
        assertEq(_swapFee(vm.getRecordedLogs()), 10_000);
    }

    function test_MultiPoolConfigurationAndAccountingIsolation() public {
        vm.startPrank(KEEPER);
        hook.setHookFee(poolId, 11);
        hook.setLpFee(poolId, 6_000);
        vm.stopPrank();

        (uint24 firstLp, uint16 firstHook,) = hook.poolConfigs(poolId);
        (uint24 secondLp, uint16 secondHook,) = hook.poolConfigs(secondPoolId);
        assertEq(firstLp, 6_000);
        assertEq(firstHook, 11);
        assertEq(secondLp, 2_500);
        assertEq(secondHook, 5);

        Currency firstFeeCurrency = Currency.wrap(address(token1));
        Currency secondFeeCurrency = Currency.wrap(address(token2));
        uint256 firstBefore = _claimBalance(address(hook), firstFeeCurrency);
        uint256 secondBefore = _claimBalance(address(hook), secondFeeCurrency);

        // Charge exact input in token1 for the first pool.
        bool firstZeroForOne = key.currency0 == firstFeeCurrency;
        _swapExactInput(key, firstZeroForOne, 10 ether);
        assertEq(_claimBalance(address(hook), firstFeeCurrency) - firstBefore, 10 ether * 11 / 10_000);
        assertEq(_claimBalance(address(hook), secondFeeCurrency), secondBefore);

        // Charge exact output in token2 for the second pool.
        bool secondZeroForOne = secondKey.currency1 == secondFeeCurrency;
        _swapExactOutput(secondKey, secondZeroForOne, 1 ether, 100 ether);
        assertEq(_claimBalance(address(hook), secondFeeCurrency) - secondBefore, 1 ether * 5 / 10_000);
        assertEq(_claimBalance(address(hook), firstFeeCurrency) - firstBefore, 10 ether * 11 / 10_000);
    }

    function test_CollectFeesRedeemsERC20ToTreasury() public {
        _swapExactInput(key, true, 10 ether);
        Currency currency = key.currency0;
        MockERC20 token = MockERC20(Currency.unwrap(currency));
        uint256 accrued = _claimBalance(address(hook), currency);
        uint256 treasuryTokenBefore = token.balanceOf(TREASURY);

        vm.prank(address(0xBAD));
        uint256 collected = hook.collectFees(currency);

        assertEq(collected, accrued);
        assertEq(_claimBalance(address(hook), currency), 0);
        assertEq(_claimBalance(TREASURY, currency), 0);
        assertEq(token.balanceOf(TREASURY), treasuryTokenBefore + accrued);
    }

    function test_CollectFeesZeroBalanceReturnsSilently() public {
        Currency currency = Currency.wrap(address(0x1234));
        vm.recordLogs();
        vm.prank(address(0xBAD));
        assertEq(hook.collectFees(currency), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_CollectFeesRedeemsNativeToTreasury() public {
        PoolKey memory nativeKey = _createNativePool(hook, token2);
        uint256 beforeClaims = _claimBalance(address(hook), nativeKey.currency0);
        _swapExactInputNative(nativeKey, 10 ether);
        uint256 accrued = _claimBalance(address(hook), nativeKey.currency0) - beforeClaims;
        uint256 treasuryBefore = TREASURY.balance;

        hook.collectFees(nativeKey.currency0);

        assertEq(_claimBalance(address(hook), nativeKey.currency0), 0);
        assertEq(TREASURY.balance, treasuryBefore + accrued);
        assertEq(_claimBalance(TREASURY, nativeKey.currency0), 0);
    }

    function test_CollectUnlockBlocksNativeTreasuryReentrancy() public {
        ReentrantTreasury reentrantTreasury = new ReentrantTreasury();
        ZiaFeeHook reentrantHook = _deployHook(address(reentrantTreasury), KEEPER, 0xC011EC7);
        PoolKey memory nativeKey = _createNativePool(reentrantHook, token2);
        reentrantTreasury.configure(reentrantHook, nativeKey.currency0);

        _swapExactInputNative(nativeKey, 10 ether);
        uint256 accrued = _claimBalance(address(reentrantHook), nativeKey.currency0);
        reentrantHook.collectFees(nativeKey.currency0);

        assertEq(address(reentrantTreasury).balance, accrued);
        assertTrue(reentrantTreasury.collectReentryBlocked());
        assertTrue(reentrantTreasury.callbackReentryBlocked());
        assertEq(_claimBalance(address(reentrantHook), nativeKey.currency0), 0);
    }

    function test_KeeperAccessControlAndCeilings() public {
        vm.expectRevert(abi.encodeWithSelector(ZiaFeeHook.NotKeeper.selector, address(this)));
        hook.setLpFee(poolId, 3_000);
        vm.expectRevert(abi.encodeWithSelector(ZiaFeeHook.NotKeeper.selector, address(this)));
        hook.setHookFee(poolId, 6);

        vm.startPrank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(ZiaFeeHook.LPFeeTooLarge.selector, uint24(10_001), uint24(10_000)));
        hook.setLpFee(poolId, 10_001);
        vm.expectRevert(abi.encodeWithSelector(ZiaFeeHook.HookFeeTooLarge.selector, uint16(26), uint16(25)));
        hook.setHookFee(poolId, 26);
        vm.stopPrank();
    }

    function test_UnknownPoolSettersAndSwapRevert() public {
        PoolId unknown = PoolId.wrap(bytes32(uint256(123)));
        vm.startPrank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(ZiaFeeHook.PoolNotInitialized.selector, unknown));
        hook.setLpFee(unknown, 3_000);
        vm.expectRevert(abi.encodeWithSelector(ZiaFeeHook.PoolNotInitialized.selector, unknown));
        hook.setHookFee(unknown, 6);
        vm.stopPrank();

        PoolKey memory unknownKey = key;
        unknownKey.tickSpacing = 120;
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(ZiaFeeHook.PoolNotInitialized.selector, unknownKey.toId()));
        hook.beforeSwap(address(this), unknownKey, params, bytes(""));
    }

    function test_CallbackAndUnlockGates() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.unlockCallback(bytes(""));

        vm.prank(address(poolManager));
        vm.expectRevert(ZiaFeeHook.UnauthorizedUnlock.selector);
        hook.unlockCallback(abi.encode(key.currency0, uint256(1)));
    }

    function test_DuplicateInitializationCallbackReverts() public {
        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(ZiaFeeHook.PoolAlreadyInitialized.selector, poolId));
        hook.beforeInitialize(address(this), key, Q96);
    }

    function test_OversizedSwapAmountsRevertBeforeClaimMint() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: type(int256).min, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.prank(address(poolManager));
        vm.expectRevert(ZiaFeeHook.SwapAmountTooLarge.selector);
        hook.beforeSwap(address(this), key, params, bytes(""));

        params.amountSpecified = int256(uint256(uint128(type(int128).max)) + 1);
        vm.prank(address(poolManager));
        vm.expectRevert(ZiaFeeHook.SwapAmountTooLarge.selector);
        hook.beforeSwap(address(this), key, params, bytes(""));

        params.amountSpecified = int256(uint256(uint128(type(int128).max)));
        vm.prank(address(poolManager));
        vm.expectRevert(ZiaFeeHook.SwapAmountTooLarge.selector);
        hook.beforeSwap(address(this), key, params, bytes(""));
    }

    function testFuzz_SpecifiedFeeBothSwapTypesAndDirections(uint64 rawAmount, bool zeroForOne, bool exactInput)
        public
    {
        uint256 amount = bound(uint256(rawAmount), 1, 5 ether);
        _assertSpecifiedFee(key, zeroForOne, exactInput, amount, 5);
    }

    function _assertSpecifiedFee(
        PoolKey memory poolKey,
        bool zeroForOne,
        bool exactInput,
        uint256 specifiedAmount,
        uint16 bps
    ) internal {
        Currency specified = _specifiedCurrency(poolKey, zeroForOne, exactInput);
        Currency unspecified = specified == poolKey.currency0 ? poolKey.currency1 : poolKey.currency0;
        uint256 specifiedClaimsBefore = _claimBalance(address(hook), specified);
        uint256 unspecifiedClaimsBefore = _claimBalance(address(hook), unspecified);

        if (exactInput) {
            _swapExactInput(poolKey, zeroForOne, specifiedAmount);
        } else {
            uint256 outputBefore = MockERC20(Currency.unwrap(specified)).balanceOf(address(this));
            _swapExactOutput(poolKey, zeroForOne, specifiedAmount, 100 ether);
            assertEq(MockERC20(Currency.unwrap(specified)).balanceOf(address(this)) - outputBefore, specifiedAmount);
        }

        assertEq(_claimBalance(address(hook), specified) - specifiedClaimsBefore, specifiedAmount * bps / 10_000);
        assertEq(_claimBalance(address(hook), unspecified), unspecifiedClaimsBefore);
    }

    function _specifiedCurrency(PoolKey memory poolKey, bool zeroForOne, bool exactInput)
        internal
        pure
        returns (Currency)
    {
        return exactInput == zeroForOne ? poolKey.currency0 : poolKey.currency1;
    }

    function _swapExactInput(PoolKey memory poolKey, bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens(
            amountIn, 0, zeroForOne, poolKey, bytes("ignored"), address(this), block.timestamp
        );
    }

    function _swapExactOutput(PoolKey memory poolKey, bool zeroForOne, uint256 amountOut, uint256 amountInMax)
        internal
    {
        swapRouter.swapTokensForExactTokens(
            amountOut, amountInMax, zeroForOne, poolKey, bytes("ignored"), address(this), block.timestamp
        );
    }

    function _swapExactInputNative(PoolKey memory nativeKey, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens{value: amountIn}(
            amountIn, 0, true, nativeKey, bytes(""), address(this), block.timestamp
        );
    }

    function _sortedKey(MockERC20 a, MockERC20 b, ZiaFeeHook hook_) internal pure returns (PoolKey memory) {
        (Currency currency0, Currency currency1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));
        return _key(currency0, currency1, hook_);
    }

    function _key(Currency currency0, Currency currency1, ZiaFeeHook hook_) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook_)
        });
    }

    function _createNativePool(ZiaFeeHook hook_, MockERC20 token) internal returns (PoolKey memory nativeKey) {
        vm.deal(address(this), 10_000 ether);
        nativeKey = _key(Currency.wrap(address(0)), Currency.wrap(address(token)), hook_);
        poolManager.initialize(nativeKey, Q96);
        _seed(nativeKey, 1_000 ether, 1_000 ether);
    }

    function _deployHook(address treasury_, address keeper_, uint160 prefix) internal returns (ZiaFeeHook deployed) {
        address hookAddress = address(_requiredFlags() ^ (prefix << 120));
        deployCodeTo("ZiaFeeHook.sol:ZiaFeeHook", abi.encode(poolManager, treasury_, keeper_), hookAddress);
        return ZiaFeeHook(hookAddress);
    }

    function _flagAddress(uint160 prefix) internal pure returns (address) {
        return address(_requiredFlags() ^ (prefix << 120));
    }

    function _requiredFlags() internal pure returns (uint160) {
        return uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
    }

    function _approve(MockERC20 token) internal {
        token.approve(address(permit2), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token), address(poolManager), type(uint160).max, type(uint48).max);
    }

    function _seed(PoolKey memory poolKey, uint256 amount0, uint256 amount1) internal {
        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            Q96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
        );
        positionManager.mint(
            poolKey, lower, upper, liquidity, amount0, amount1, address(this), block.timestamp, bytes("")
        );
    }

    function _claimBalance(address owner, Currency currency) internal view returns (uint256) {
        return poolManager.balanceOf(owner, currency.toId());
    }

    function _swapFee(Vm.Log[] memory logs) internal pure returns (uint24 fee) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == SWAP_EVENT_SIGNATURE) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("Swap event not found");
    }
}
