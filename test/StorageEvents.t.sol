//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {RagequitVault} from "../src/RagequitVault.sol";
import {console2 as console} from "forge-std/console2.sol"; // optional

contract StorageEvents is Test {
    RagequitVault vault;
    address TREASURY = address(0xBEEF);
    // add near the top if you don’t already have a USER
    address USER = makeAddr("user");

    // mirror the event so expectEmit can match it
    event Withdrawn(
        uint256 indexed id,
        address indexed owner,
        uint256 principal,
        uint256 reward
    );

    function setUp() public {
        vault = new RagequitVault({
            _maxPenaltyBps: 500,
            _treasuryFeeBps: 100,
            _treasury: TREASURY
        });
    }

    function testConstructorParamsAreSet() public view {
        assertEq(vault.maxPenaltyBps(), 500);
        assertEq(vault.treasuryFeeBps(), 100);
        assertEq(vault.treasury(), TREASURY);
    }

    function testInitialAccountingIsZeroed() public view {
        assertEq(vault.totalShares(), 0);
        assertEq(vault.accPenaltyPerShare(), 0);
        assertEq(vault.nextId(), 1);
    }

    function testConstructorRevertsOnBadInput() public {
        // treasury = zero
        vm.expectRevert();
        new RagequitVault(500, 100, address(0));

        // bps > 100%
        vm.expectRevert();
        new RagequitVault(10_001, 0, TREASURY);

        vm.expectRevert();
        new RagequitVault(0, 10_001, TREASURY);
    }

    function testDepositRevertsOnZeroAmount() public {
        vm.expectRevert();
        vault.deposit{value: 0}(1 days);
    }

    function testDepositRevertsOnZeroDuration() public {
        vm.expectRevert();
        vault.deposit{value: 1}(0);
    }

    function testDepositStoresPositionAndEmitsEvent() public {
        uint256 duration = 30 days;

        vm.expectEmit(true, true, true, true);
        emit Deposited(1, address(this), 1 ether, duration);

        uint256 id = vault.deposit{value: 1 ether}(duration);
        assertEq(id, 1);
        assertEq(vault.totalShares(), 1 ether);
        assertEq(vault.nextId(), 2);
        console.log(vault.nextId());

        // Read back the stored position
        (
            address owner,
            uint96 shares,
            uint256 start,
            uint256 unlockAt,
            uint256 rewardDebt
        ) = vault.positions(id);
        assertEq(owner, address(this));
        assertEq(shares, uint96(1 ether));
        assertGt(start, 0);
        assertEq(unlockAt - start, duration);
        // With accPenaltyPerShare == 0 at start, rewardDebt should be 0
        assertEq(rewardDebt, 0);
    }

    event Deposited(
        uint256 indexed id,
        address indexed owner,
        uint256 amount,
        uint256 duration
    );

    function testPendingRewardIsZeroRightAfterDeposit() public {
        uint256 id = vault.deposit{value: 1 ether}(30 days);

        // no penalties have been distributed yet, so nothing is owed
        assertEq(vault.pendingReward(id), 0);
    }

    function testWithdrawRevertsIfNotMature() public {
        vm.deal(address(this), 10 ether);
        uint256 duration = 30 days;
        uint256 id = vault.deposit{value: 1 ether}(duration);

        // no warp → still locked
        vm.expectRevert(); // your function should revert if block.timestamp < unlockAt
        vault.withdraw(id);
    }

    function testWithdrawRevertsIfNotOwner() public {
        vm.deal(address(this), 10 ether);
        uint256 id = vault.deposit{value: 1 ether}(7 days);

        // fast-forward to or past unlock
        vm.warp(block.timestamp + 7 days + 5);

        // someone else tries to withdraw
        vm.prank(USER);
        vm.expectRevert(); // your function should check ownership
        vault.withdraw(id);
    }

    function testWithdrawAtMaturityPaysPrincipalAndClearsPosition() public {
        vm.deal(USER, 10 ether);
        vm.txGasPrice(0);

        uint256 duration = 14 days;
        vm.prank(USER);
        uint256 id = vault.deposit{value: 1 ether}(duration);

        // capture pre-state
        uint256 preUser = USER.balance;
        uint256 preVault = address(vault).balance;
        uint256 preAcc = vault.accPenaltyPerShare();
        uint256 preTotalShares = vault.totalShares();

        // mature
        vm.warp(block.timestamp + duration + 1);

        // expect the Withdrawn event (reward = 0 in this phase)
        vm.expectEmit(true, true, false, true);
        // vm.expectEmit(address(vault));
        // vm.expectEmit(address(vault), true, true, false, true);

        emit Withdrawn(id, USER, 1 ether, 0);

        vm.prank(USER);

        vault.withdraw(id);

        // balances & accounting
        assertEq(USER.balance, preUser + 1 ether);
        assertEq(address(vault).balance, preVault - 1 ether);
        assertEq(vault.accPenaltyPerShare(), preAcc); // no change on mature withdraw
        assertEq(vault.totalShares(), preTotalShares - 1 ether);

        // position is cleared
        (
            address owner,
            uint96 shares,
            uint256 start,
            uint256 unlockAt,
            uint256 rewardDebt
        ) = vault.positions(id);
        assertEq(owner, address(0));
        assertEq(shares, 0);
        assertEq(start, 0);
        assertEq(unlockAt, 0);
        assertEq(rewardDebt, 0);
    }
}
