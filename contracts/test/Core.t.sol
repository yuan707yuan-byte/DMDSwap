// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Fixture} from "./utils/Fixture.sol";
import {DmdSwapPair} from "../src/core/DmdSwapPair.sol";
import {DmdSwapFactory} from "../src/core/DmdSwapFactory.sol";
import {IDmdSwapPair} from "../src/interfaces/IDmdSwapPair.sol";
import {MockERC20, FlashBorrower, BlacklistToken} from "./mocks/Mocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract CoreTest is Fixture {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ───────────────────────────── factory

    function test_createPair_sortsIndexesAndInitializes() public {
        address pair = factory.createPair(address(tokB), address(tokA));
        (address t0, address t1) = address(tokA) < address(tokB) ? (address(tokA), address(tokB)) : (address(tokB), address(tokA));
        assertEq(factory.getPair(address(tokA), address(tokB)), pair);
        assertEq(factory.getPair(address(tokB), address(tokA)), pair);
        assertEq(factory.allPairsLength(), 1);
        assertEq(IDmdSwapPair(pair).token0(), t0);
        assertEq(IDmdSwapPair(pair).token1(), t1);
        assertEq(IDmdSwapPair(pair).factory(), address(factory));
        // pair cannot be re-initialized
        vm.expectRevert();
        IDmdSwapPair(pair).initialize(t0, t1);
    }

    function test_createPair_rejectsBadInput() public {
        factory.createPair(address(tokA), address(tokB));
        vm.expectRevert(abi.encodeWithSelector(DmdSwapFactory.PairExists.selector, factory.getPair(address(tokA), address(tokB))));
        factory.createPair(address(tokB), address(tokA));
        vm.expectRevert(DmdSwapFactory.IdenticalAddresses.selector);
        factory.createPair(address(tokA), address(tokA));
        vm.expectRevert(DmdSwapFactory.ZeroAddress.selector);
        factory.createPair(address(0), address(tokA));
        vm.expectRevert(abi.encodeWithSelector(DmdSwapFactory.NotAContract.selector, alice));
        factory.createPair(alice, address(tokC));
    }

    // ───────────────────────────── mint / burn

    function test_firstMint_locksMinimumLiquidity() public {
        address pair = _addLiq(alice, address(tokA), address(tokB), 1e18, 4e18);
        assertEq(DmdSwapPair(pair).balanceOf(DEAD), 1000);
        assertEq(DmdSwapPair(pair).balanceOf(alice), 2e18 - 1000);
        assertEq(DmdSwapPair(pair).totalSupply(), 2e18);
    }

    function test_firstMint_tooSmall_reverts() public {
        vm.prank(alice);
        vm.expectRevert(DmdSwapPair.InsufficientLiquidityMinted.selector);
        router.addLiquidity(address(tokA), address(tokB), 1000, 1000, 0, 0, alice, block.timestamp);
    }

    /// First-depositor / donation inflation attack: attacker mints dust then donates to inflate share price.
    function test_inflationAttack_isUnprofitable() public {
        address pair = _addLiq(attacker, address(tokA), address(tokB), 1001, 1001); // 1 LP wei to attacker
        assertEq(DmdSwapPair(pair).balanceOf(attacker), 1);
        vm.startPrank(attacker);
        tokA.transfer(pair, 1e21); // huge donation
        tokB.transfer(pair, 1e21);
        IDmdSwapPair(pair).sync();
        vm.stopPrank();
        // victim deposits; gets a fair share (rounding loss bounded) because 1000 LP is locked at DEAD
        _addLiq(bob, address(tokA), address(tokB), 1e21, 1e21);
        uint256 bobShare = DmdSwapPair(pair).balanceOf(bob) * 1e18 / DmdSwapPair(pair).totalSupply();
        assertGt(bobShare, 0.49e18); // bob owns ~half, attacker's donation is mostly lost to DEAD share
        // attacker cannot extract more than they put in
        uint256 attackerLp = DmdSwapPair(pair).balanceOf(attacker);
        uint256 attackerValueA = attackerLp * tokA.balanceOf(pair) / DmdSwapPair(pair).totalSupply();
        assertLt(attackerValueA, 1e21 + 1001);
    }

    function test_burn_isProRata() public {
        address pair = _addLiq(alice, address(tokA), address(tokB), 10e18, 10e18);
        uint256 lp = DmdSwapPair(pair).balanceOf(alice);
        uint256 a0 = tokA.balanceOf(alice);
        vm.startPrank(alice);
        DmdSwapPair(pair).approve(address(router), lp);
        router.removeLiquidity(address(tokA), address(tokB), lp, 0, 0, alice, block.timestamp);
        vm.stopPrank();
        assertEq(tokA.balanceOf(alice) - a0, 10e18 - 1000); // everything except locked minimum
    }

    // ───────────────────────────── swap math (fuzz)

    function testFuzz_swap_libraryQuoteIsExactBoundary(uint112 rA, uint112 rB, uint112 amountIn) public {
        rA = uint112(bound(rA, 1e6, 1e30));
        rB = uint112(bound(rB, 1e6, 1e30));
        amountIn = uint112(bound(amountIn, 1, 1e30));
        address pair = _addLiq(alice, address(tokA), address(tokB), rA, rB);
        uint256 out = router.getAmountOut(amountIn, rA, rB);
        vm.assume(out > 0 && out < rB);
        bool aIs0 = IDmdSwapPair(pair).token0() == address(tokA);

        // out + 1 must be rejected (K violation, or reserve exhaustion at the boundary)
        vm.startPrank(bob);
        tokA.transfer(pair, amountIn);
        if (out + 1 >= rB) vm.expectRevert(DmdSwapPair.InsufficientLiquidity.selector);
        else vm.expectRevert(DmdSwapPair.KInvariant.selector);
        IDmdSwapPair(pair).swap(aIs0 ? 0 : out + 1, aIs0 ? out + 1 : 0, bob, "");
        // exactly `out` must succeed
        IDmdSwapPair(pair).swap(aIs0 ? 0 : out, aIs0 ? out : 0, bob, "");
        vm.stopPrank();
    }

    function testFuzz_swap_neverDecreasesK(uint96 amountIn, bool aToB) public {
        amountIn = uint96(bound(amountIn, 1e3, 1e26));
        address pair = _addLiq(alice, address(tokA), address(tokB), 1e24, 3e24);
        (uint112 r0, uint112 r1,) = IDmdSwapPair(pair).getReserves();
        uint256 kBefore = uint256(r0) * r1;
        (address i, address o) = aToB ? (address(tokA), address(tokB)) : (address(tokB), address(tokA));
        uint256[] memory amounts = router.getAmountsOut(amountIn, _path(i, o));
        vm.assume(amounts[1] > 0);
        vm.prank(bob);
        router.swapExactTokensForTokens(amountIn, amounts[1], _path(i, o), bob, block.timestamp);
        (r0, r1,) = IDmdSwapPair(pair).getReserves();
        assertGe(uint256(r0) * r1, kBefore);
    }

    function test_swap_toTokenAddress_reverts() public {
        address pair = _addLiq(alice, address(tokA), address(tokB), 1e20, 1e20);
        address t1 = IDmdSwapPair(pair).token1();
        vm.startPrank(bob);
        tokA.transfer(pair, 1e18);
        vm.expectRevert(DmdSwapPair.InvalidTo.selector);
        IDmdSwapPair(pair).swap(0, 1e17, t1, "");
        vm.stopPrank();
    }

    // ───────────────────────────── flash swaps & reentrancy

    function test_flashSwap_repaidWithFee_succeeds() public {
        address pair = _addLiq(alice, address(tokA), address(tokB), 1e22, 1e22);
        FlashBorrower fb = new FlashBorrower();
        tokA.mint(address(fb), 1e21);
        tokB.mint(address(fb), 1e21);
        fb.setMode(0);
        fb.borrow(pair, 1e20, 0);
    }

    function test_flashSwap_unpaidOrNoFee_reverts() public {
        address pair = _addLiq(alice, address(tokA), address(tokB), 1e22, 1e22);
        FlashBorrower fb = new FlashBorrower();
        tokA.mint(address(fb), 1e21);
        tokB.mint(address(fb), 1e21);
        fb.setMode(1);
        vm.expectRevert(DmdSwapPair.InsufficientInputAmount.selector);
        fb.borrow(pair, 1e20, 0);
        fb.setMode(2);
        vm.expectRevert(DmdSwapPair.KInvariant.selector);
        fb.borrow(pair, 1e20, 0);
    }

    function test_readOnlyReentrancy_getReservesRevertsMidSwap() public {
        address pair = _addLiq(alice, address(tokA), address(tokB), 1e22, 1e22);
        FlashBorrower fb = new FlashBorrower();
        tokA.mint(address(fb), 1e21);
        tokB.mint(address(fb), 1e21);
        fb.setMode(3);
        fb.borrow(pair, 1e20, 0);
        assertTrue(fb.getReservesReverted(), "stale reserves must not be readable mid-swap");
        fb.setMode(4);
        fb.borrow(pair, 1e20, 0);
        assertTrue(fb.reentryReverted(), "pair must be locked during callback");
    }

    // ───────────────────────────── pause

    function test_pause_blocksTradingButNeverExits() public {
        address pair = _addLiq(alice, address(tokA), address(tokB), 1e20, 1e20);
        vm.prank(attacker);
        vm.expectRevert(DmdSwapFactory.Unauthorized.selector);
        factory.pause();

        vm.prank(admin); // guardian: instant
        factory.pause();

        vm.startPrank(bob);
        vm.expectRevert(DmdSwapPair.Paused.selector);
        router.swapExactTokensForTokens(1e18, 1, _path(address(tokA), address(tokB)), bob, block.timestamp);
        vm.expectRevert(DmdSwapPair.Paused.selector);
        router.addLiquidity(address(tokA), address(tokB), 1e18, 1e18, 0, 0, bob, block.timestamp);
        vm.expectRevert(DmdSwapFactory.Paused.selector);
        factory.createPair(address(tokA), address(tokC));
        vm.stopPrank();

        // LP exit still works while paused
        uint256 lp = DmdSwapPair(pair).balanceOf(alice);
        vm.startPrank(alice);
        DmdSwapPair(pair).approve(address(router), lp);
        router.removeLiquidity(address(tokA), address(tokB), lp, 0, 0, alice, block.timestamp);
        vm.stopPrank();
        assertEq(DmdSwapPair(pair).balanceOf(alice), 0);

        // guardian cannot unpause; only the timelock can
        vm.prank(admin);
        vm.expectRevert();
        factory.unpause();
        _govern(address(factory), abi.encodeCall(DmdSwapFactory.unpause, ()));
        assertFalse(factory.swapsPaused());
    }

    // ───────────────────────────── protocol fee: half of every swap fee paid directly to admin

    function test_protocolFee_halfPaidDirectlyToAdmin_fromFirstSwap() public {
        assertEq(factory.feeTo(), admin);
        assertEq(factory.protocolFeeShareBps(), 5_000);
        address pair = _addLiq(alice, address(tokA), address(tokB), 1e24, 1e24);
        uint256 amountIn = 1e22;
        uint256 adminBefore = tokA.balanceOf(admin);
        (uint112 r0, uint112 r1,) = IDmdSwapPair(pair).getReserves();
        bool aIs0 = IDmdSwapPair(pair).token0() == address(tokA);
        uint256 rA = aIs0 ? r0 : r1;

        uint256 out = router.getAmountsOut(amountIn, _path(address(tokA), address(tokB)))[1];
        vm.prank(bob);
        router.swapExactTokensForTokens(amountIn, out, _path(address(tokA), address(tokB)), bob, block.timestamp);

        uint256 totalFee = amountIn * 30 / 10_000;                // 0.30 % paid by trader
        uint256 adminCut = tokA.balanceOf(admin) - adminBefore;
        assertEq(adminCut, totalFee / 2, "admin receives exactly half, in the input token, immediately");
        (r0, r1,) = IDmdSwapPair(pair).getReserves();
        uint256 rAAfter = aIs0 ? r0 : r1;
        assertEq(rAAfter - rA, amountIn - adminCut, "other half stays in the pool for LPs");
    }

    function test_protocolFee_bothDirectionsAndMultiHop() public {
        _addLiq(alice, address(tokA), address(tokB), 1e24, 1e24);
        _addLiq(alice, address(tokB), address(tokC), 1e24, 1e12);
        uint256 a0 = tokA.balanceOf(admin);
        uint256 b0 = tokB.balanceOf(admin);
        address[] memory p = _path3(address(tokA), address(tokB), address(tokC));
        uint256[] memory q = router.getAmountsOut(1e21, p);
        vm.prank(bob);
        router.swapExactTokensForTokens(1e21, q[2], p, bob, block.timestamp);
        assertEq(tokA.balanceOf(admin) - a0, 1e21 * 15 / 10_000, "hop 1 fee in tokA");
        assertEq(tokB.balanceOf(admin) - b0, q[1] * 15 / 10_000, "hop 2 fee in tokB");
    }

    function test_protocolFee_dmdTradesPayAdminInWDMD() public {
        _addLiqDMD(alice, address(tokA), 1e24, 1e5 ether);
        uint256 w0 = wdmd.balanceOf(admin);
        vm.prank(bob);
        router.swapExactDMDForTokens{value: 100 ether}(1, _path(address(wdmd), address(tokA)), bob, block.timestamp);
        assertEq(wdmd.balanceOf(admin) - w0, 100 ether * 15 / 10_000);
        uint256 d0 = admin.balance;
        uint256 wBal = wdmd.balanceOf(admin);
        vm.prank(admin);
        wdmd.withdraw(wBal); // admin can unwrap to native DMD anytime
        assertEq(admin.balance - d0, 100 ether * 15 / 10_000);
    }

    function test_protocolFee_flashSwapAlsoPays() public {
        address pair = _addLiq(alice, address(tokA), address(tokB), 1e22, 1e22);
        FlashBorrower fb = new FlashBorrower();
        tokA.mint(address(fb), 1e21);
        tokB.mint(address(fb), 1e21);
        bool aIs0 = IDmdSwapPair(pair).token0() == address(tokA);
        uint256 before = tokA.balanceOf(admin);
        fb.borrow(pair, aIs0 ? 1e20 : 0, aIs0 ? 0 : 1e20);
        assertGt(tokA.balanceOf(admin), before);
    }

    function testFuzz_protocolFee_neverExceedsHalfAndKNeverDecreases(uint96 amountIn) public {
        amountIn = uint96(bound(amountIn, 1e3, 1e25));
        address pair = _addLiq(alice, address(tokA), address(tokB), 1e24, 1e24);
        (uint112 r0, uint112 r1,) = IDmdSwapPair(pair).getReserves();
        uint256[] memory q = router.getAmountsOut(amountIn, _path(address(tokA), address(tokB)));
        vm.assume(q[1] > 0);
        uint256 before = tokA.balanceOf(admin);
        vm.prank(bob);
        router.swapExactTokensForTokens(amountIn, q[1], _path(address(tokA), address(tokB)), bob, block.timestamp);
        uint256 cut = tokA.balanceOf(admin) - before;
        assertLe(cut * 2, uint256(amountIn) * 30 / 10_000 + 1);
        (uint112 n0, uint112 n1,) = IDmdSwapPair(pair).getReserves();
        assertGe(uint256(n0) * n1, uint256(r0) * r1);
    }

    function test_protocolFee_canBeRedirectedOrDisabledOnlyViaTimelock() public {
        _addLiq(alice, address(tokA), address(tokB), 1e24, 1e24);
        vm.prank(admin);
        vm.expectRevert();
        factory.setFeeTo(attacker);
        _govern(address(factory), abi.encodeCall(DmdSwapFactory.setFeeTo, (carol)));
        vm.prank(bob);
        router.swapExactTokensForTokens(1e21, 1, _path(address(tokA), address(tokB)), bob, block.timestamp);
        assertEq(tokA.balanceOf(carol) - 1e30, 1e21 * 15 / 10_000);
        _govern(address(factory), abi.encodeCall(DmdSwapFactory.setFeeTo, (address(0))));
        uint256 c = tokA.balanceOf(carol);
        vm.prank(bob);
        router.swapExactTokensForTokens(1e21, 1, _path(address(tokA), address(tokB)), bob, block.timestamp);
        assertEq(tokA.balanceOf(carol), c, "disabled: 100 % of fee stays with LPs");
    }

    function test_protocolFee_hostileTokenCannotBrickPool() public {
        BlacklistToken bt = new BlacklistToken();
        bt.mint(alice, 1e24);
        bt.mint(bob, 1e24);
        vm.prank(alice);
        bt.approve(address(router), type(uint256).max);
        vm.prank(bob);
        bt.approve(address(router), type(uint256).max);
        _addLiq(alice, address(bt), address(tokA), 1e22, 1e22);
        bt.setBlocked(admin, true); // token refuses transfers to the fee recipient
        vm.prank(bob);
        router.swapExactTokensForTokens(1e20, 1, _path(address(bt), address(tokA)), bob, block.timestamp);
        assertEq(bt.balanceOf(admin), 0); // fee stayed with LPs, swap still worked
    }

    function test_governance_feeBoundsAreHard() public {
        bytes memory data = abi.encodeCall(DmdSwapFactory.setSwapFee, (uint16(101)));
        bytes32 salt = keccak256("x");
        vm.prank(admin);
        timelock.schedule(address(factory), 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(admin);
        vm.expectRevert(); // FeeTooHigh bubbles through the timelock
        timelock.execute(address(factory), 0, data, bytes32(0), salt);
    }

    // ───────────────────────────── skim / sync / overflow / TWAP

    function test_skimAndSync() public {
        address pair = _addLiq(alice, address(tokA), address(tokB), 1e20, 1e20);
        vm.prank(bob);
        tokA.transfer(pair, 5e18);
        uint256 before = tokA.balanceOf(carol);
        IDmdSwapPair(pair).skim(carol);
        assertEq(tokA.balanceOf(carol) - before, 5e18);
        vm.prank(bob);
        tokA.transfer(pair, 5e18);
        IDmdSwapPair(pair).sync();
        (uint112 r0, uint112 r1,) = IDmdSwapPair(pair).getReserves();
        assertEq(uint256(r0) + r1, 2e20 + 5e18);
    }

    function test_uint112Overflow_reverts() public {
        address pair = _addLiq(alice, address(tokA), address(tokB), 1e20, 1e20);
        tokA.mint(pair, uint256(type(uint112).max));
        vm.expectRevert(DmdSwapPair.Overflow.selector);
        IDmdSwapPair(pair).sync();
    }

    function test_twap_accumulatesAcrossUint32Wraparound() public {
        address pair = _addLiq(alice, address(tokA), address(tokB), 2e20, 1e20);
        vm.warp(uint256(type(uint32).max) - 9); // 10s before 2^32
        IDmdSwapPair(pair).sync();
        uint256 c0 = IDmdSwapPair(pair).price0CumulativeLast();
        (uint112 r0, uint112 r1,) = IDmdSwapPair(pair).getReserves();
        vm.warp(uint256(type(uint32).max) + 11); // wraps uint32
        IDmdSwapPair(pair).sync();
        uint256 c1 = IDmdSwapPair(pair).price0CumulativeLast();
        unchecked {
            assertEq(c1 - c0, ((uint256(r1) << 112) / r0) * 20);
        }
    }

    // ───────────────────────────── LP permit

    function test_lpPermit() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        address pair = factory.createPair(address(tokA), address(tokB));
        DmdSwapPair p = DmdSwapPair(pair);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                p.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner, bob, 123, 0, block.timestamp
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        p.permit(owner, bob, 123, block.timestamp, v, r, s);
        assertEq(p.allowance(owner, bob), 123);
        vm.expectRevert(); // replay
        p.permit(owner, bob, 123, block.timestamp, v, r, s);
    }
}
