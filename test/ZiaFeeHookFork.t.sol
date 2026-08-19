// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";

import {ZiaFeeHook} from "../src/ZiaFeeHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

/// @notice Fork integration against the canonical Robinhood Chain PoolManager.
contract ZiaFeeHookForkTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal constant RH_POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IPositionManager internal constant RH_POSITION_MANAGER =
        IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    IPermit2 internal constant RH_PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    uint160 internal constant Q96 = 1 << 96;

    function testFork_CanonicalPoolManagerInitializeLiquidityAndBothSwapTypes() public {
        string memory rpcUrl = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, 4663);
        assertGt(address(RH_POOL_MANAGER).code.length, 0);

        poolManager = RH_POOL_MANAGER;
        positionManager = RH_POSITION_MANAGER;
        permit2 = RH_PERMIT2;
        swapRouter = IUniswapV4Router04(payable(V4RouterDeployer.deploy(address(poolManager), address(permit2))));

        address hookAddress = address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
                ^ (uint160(0xF04663) << 112)
        );
        deployCodeTo(
            "ZiaFeeHook.sol:ZiaFeeHook", abi.encode(poolManager, address(0xBEEF), address(0xCAFE)), hookAddress
        );
        ZiaFeeHook hook = ZiaFeeHook(hookAddress);

        MockERC20 a = new MockERC20("Fork A", "FORK-A", 18);
        MockERC20 b = new MockERC20("Fork B", "FORK-B", 18);
        a.mint(address(this), 10_000 ether);
        b.mint(address(this), 10_000 ether);
        _forkApprove(a);
        _forkApprove(b);

        (Currency currency0, Currency currency1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        poolManager.initialize(key, Q96);
        (,,, uint24 storedLpFee) = poolManager.getSlot0(key.toId());
        assertEq(storedLpFee, 0, "dynamic fee must be supplied only by the per-swap override");

        int24 lower = TickMath.minUsableTick(60);
        int24 upper = TickMath.maxUsableTick(60);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            Q96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), 1_000 ether, 1_000 ether
        );
        positionManager.mint(
            key, lower, upper, liquidity, 1_000 ether, 1_000 ether, address(this), block.timestamp, bytes("")
        );

        uint256 claimsBefore = poolManager.balanceOf(address(hook), key.currency0.toId());
        swapRouter.swapExactTokensForTokens(10 ether, 0, true, key, bytes(""), address(this), block.timestamp);
        assertEq(poolManager.balanceOf(address(hook), key.currency0.toId()) - claimsBefore, 0.005 ether);

        // oneForZero exact output specifies currency0, so its fee is also denominated in currency0.
        claimsBefore = poolManager.balanceOf(address(hook), key.currency0.toId());
        swapRouter.swapTokensForExactTokens(1 ether, 100 ether, false, key, bytes(""), address(this), block.timestamp);
        assertEq(poolManager.balanceOf(address(hook), key.currency0.toId()) - claimsBefore, 0.0005 ether);

        _assertCollectsUnderlyingToTreasury(hook, key.currency0);

        (,,, storedLpFee) = poolManager.getSlot0(key.toId());
        assertEq(storedLpFee, 0, "swaps must not synchronize PoolManager LP fee storage");
    }

    function _forkApprove(MockERC20 token) private {
        token.approve(address(permit2), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token), address(poolManager), type(uint160).max, type(uint48).max);
    }

    function _assertCollectsUnderlyingToTreasury(ZiaFeeHook hook, Currency currency) private {
        MockERC20 feeToken = MockERC20(Currency.unwrap(currency));
        uint256 totalClaims = poolManager.balanceOf(address(hook), currency.toId());
        uint256 treasuryBefore = feeToken.balanceOf(address(0xBEEF));

        hook.collectFees(currency);

        assertEq(poolManager.balanceOf(address(hook), currency.toId()), 0);
        assertEq(poolManager.balanceOf(address(0xBEEF), currency.toId()), 0);
        assertEq(feeToken.balanceOf(address(0xBEEF)), treasuryBefore + totalClaims);
    }
}
