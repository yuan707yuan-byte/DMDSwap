// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./utils/Fixture.sol";
import {DmdSwapPair} from "../src/core/DmdSwapPair.sol";
import {DmdSwapRouter} from "../src/periphery/DmdSwapRouter.sol";
import {IDmdSwapPair} from "../src/interfaces/IDmdSwapPair.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract Handler is Test {
    DmdSwapRouter internal router;
    IDmdSwapPair internal pair;
    MockERC20 internal a;
    MockERC20 internal b;
    address[3] internal actors;

    bool public kDecreasedOnSwap;
    bool public lpBackingDecreased;
    uint256 public calls;

    constructor(DmdSwapRouter router_, IDmdSwapPair pair_, MockERC20 a_, MockERC20 b_, address[3] memory actors_) {
        (router, pair, a, b, actors) = (router_, pair_, a_, b_, actors_);
    }

    function _state() internal view returns (uint256 r0, uint256 r1, uint256 supply) {
        (uint112 x, uint112 y,) = pair.getReserves();
        return (x, y, DmdSwapPair(address(pair)).totalSupply());
    }

    /// @dev Exact check (no sqrt, no division): each token's backing per LP share must not decrease:
    ///      r0'/T' >= r0/T  <=>  r0' * T >= r0 * T'   (all values < 2^112, products fit in uint256)
    function _checkBacking(uint256 r0, uint256 r1, uint256 t) internal {
        (uint256 n0, uint256 n1, uint256 nt) = _state();
        if (n0 * t < r0 * nt || n1 * t < r1 * nt) lpBackingDecreased = true;
    }

    function swap(uint256 actorSeed, uint256 amount, bool aToB) external {
        address actor = actors[actorSeed % 3];
        amount = bound(amount, 1e9, 1e23);
        address[] memory p = new address[](2);
        (p[0], p[1]) = aToB ? (address(a), address(b)) : (address(b), address(a));
        (uint256 r0, uint256 r1,) = _state();
        uint256[] memory q = router.getAmountsOut(amount, p);
        if (q[1] == 0) return;
        vm.prank(actor);
        router.swapExactTokensForTokens(amount, q[1], p, actor, block.timestamp);
        (uint256 n0, uint256 n1,) = _state();
        if (n0 * n1 < r0 * r1) kDecreasedOnSwap = true;
        ++calls;
    }

    function add(uint256 actorSeed, uint256 amtA, uint256 amtB) external {
        address actor = actors[actorSeed % 3];
        amtA = bound(amtA, 1e12, 1e23);
        amtB = bound(amtB, 1e12, 1e23);
        (uint256 r0, uint256 r1, uint256 t) = _state();
        vm.prank(actor);
        try router.addLiquidity(address(a), address(b), amtA, amtB, 0, 0, actor, block.timestamp) {
            _checkBacking(r0, r1, t);
            ++calls;
        } catch {}
    }

    function remove(uint256 actorSeed, uint256 frac) external {
        address actor = actors[actorSeed % 3];
        uint256 bal = DmdSwapPair(address(pair)).balanceOf(actor);
        uint256 lp = bal * bound(frac, 1, 100) / 100;
        if (lp == 0) return;
        (uint256 r0, uint256 r1, uint256 t) = _state();
        vm.prank(actor);
        try router.removeLiquidity(address(a), address(b), lp, 0, 0, actor, block.timestamp) {
            _checkBacking(r0, r1, t);
            ++calls;
        } catch {}
    }
}

contract InvariantTest is Fixture {
    Handler internal handler;
    IDmdSwapPair internal pair;

    function setUp() public override {
        super.setUp();
        pair = IDmdSwapPair(_addLiq(alice, address(tokA), address(tokB), 1e24, 1e24));
        address[3] memory actors = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            vm.prank(actors[i]);
            DmdSwapPair(address(pair)).approve(address(router), type(uint256).max);
        }
        handler = new Handler(router, pair, tokA, tokB, actors);
        targetContract(address(handler));
    }

    function invariant_reservesEqualBalances() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, MockERC20(pair.token0()).balanceOf(address(pair)));
        assertEq(r1, MockERC20(pair.token1()).balanceOf(address(pair)));
    }

    function invariant_kNeverDecreasesOnSwap() public view {
        assertFalse(handler.kDecreasedOnSwap());
    }

    /// LPs can never be diluted by adds/removes (exact per-token backing check).
    function invariant_lpBackingNeverDecreases() public view {
        assertFalse(handler.lpBackingDecreased());
    }

    function invariant_sqrtKCoversSupply() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertGe(Math.sqrt(uint256(r0) * r1), DmdSwapPair(address(pair)).totalSupply());
    }

    function invariant_routersHoldNothing() public view {
        assertEq(tokA.balanceOf(address(router)), 0);
        assertEq(tokB.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
        assertEq(wdmd.balanceOf(address(router)), 0);
    }

    function invariant_lockedMinimumLiquidityNeverMoves() public view {
        assertEq(DmdSwapPair(address(pair)).balanceOf(0x000000000000000000000000000000000000dEaD), 1000);
    }
}
