// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// state-variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if-exists)
// fallback function (if-exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.24;

// Errors
error InvalidPenalty();
error InvalidTreasuryFee();
error ZeroAddressTreasury();
error ZeroDeposit();
error ZeroDuration();
error PositionDoesNotExist();
error NotOwner();
error StakeNotMatured();
error TransferFailed();
error TreasuryTransferFailed();
error AlreadyMatured();
error EmptyOwner();
error NothingToHarvest();
error ReentrantCall();
error DirectEtherNotAllowed();
error UnknownFunctionCalled();

contract RagequitVault {
    struct Position {
        address owner;
        uint96 shares;
        uint256 start;
        uint256 unlockAt;
        uint256 rewardDebt;
    }

    uint16 public immutable maxPenaltyBps;
    uint16 public immutable treasuryFeeBps;
    address public immutable treasury;
    uint256 public totalShares = 0;
    uint256 public accPenaltyPerShare = 0;
    uint256 constant PRECISION = 1e18;

    uint256 public nextId = 1;
    mapping(uint256 => Position) public positions;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    event Deposited(uint256 indexed id, address indexed owner, uint256 amount, uint256 duration);
    event Harvested(uint256 indexed id, address indexed owner, uint256 reward);
    event Ragequit(uint256 indexed id, address indexed owner, uint256 penalty, uint256 payout);
    event Withdrawn(uint256 indexed id, address indexed owner, uint256 principal, uint256 reward);
    event PenaltyDistributed(uint256 amountToStakers, uint256 accPenaltyPerShare);

    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrantCall();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor(uint16 _maxPenaltyBps, uint16 _treasuryFeeBps, address _treasury) {
        if (_maxPenaltyBps > 10000) revert InvalidPenalty();
        if (_treasuryFeeBps > 10000) revert InvalidTreasuryFee();
        if (_treasury == address(0)) revert ZeroAddressTreasury();
        maxPenaltyBps = _maxPenaltyBps;
        treasuryFeeBps = _treasuryFeeBps;
        treasury = _treasury;
    }

    receive() external payable {
        revert DirectEtherNotAllowed();
    }

    fallback() external payable {
        revert UnknownFunctionCalled();
    }

    function deposit(uint256 _durationSeconds) external payable returns (uint256 id) {
        if (msg.value == 0) revert ZeroDeposit();
        if (_durationSeconds == 0) revert ZeroDuration();
        id = nextId++;
        Position storage people = positions[id];

        people.owner = msg.sender;
        people.shares = uint96(msg.value);
        people.start = block.timestamp;
        people.unlockAt = block.timestamp + _durationSeconds;

        people.rewardDebt = (uint256(people.shares) * accPenaltyPerShare) / PRECISION;

        totalShares += people.shares;

        emit Deposited(id, people.owner, people.shares, _durationSeconds);

        return id;
    }

    function pendingReward(uint256 id) public view returns (uint256) {
        Position storage p = positions[id];

        if (p.owner == address(0)) return 0;

        uint256 accrued = (uint256(p.shares) * accPenaltyPerShare) / PRECISION;

        if (accrued <= p.rewardDebt) return 0;

        return accrued - p.rewardDebt;
    }

    function withdraw(uint256 _id) public nonReentrant {
        Position storage p = positions[_id];
        address owner = p.owner;
        if (p.owner == address(0)) revert PositionDoesNotExist();
        if (msg.sender != p.owner) revert NotOwner();
        if (block.timestamp < p.unlockAt) revert StakeNotMatured();

        uint96 principal = p.shares;
        uint256 reward = pendingReward(_id);
        totalShares -= p.shares;

        delete positions[_id];
        (bool sent,) = owner.call{value: principal + reward}("");
        if (!sent) revert TransferFailed();

        emit Withdrawn(_id, owner, principal, reward);
    }

    function ragequit(uint256 _id) public nonReentrant {
        Position storage p = positions[_id];
        address owner = p.owner;
        uint96 principal = p.shares;
        uint256 reward = pendingReward(_id);

        uint256 start = p.start;
        uint256 unlockAt = p.unlockAt;
        if (owner == address(0)) revert PositionDoesNotExist();
        if (msg.sender != owner) revert NotOwner();
        if (block.timestamp >= p.unlockAt) revert AlreadyMatured();

        uint256 totalDuration = unlockAt - start;
        uint256 remainingDuration = unlockAt - block.timestamp;
        uint256 penaltyBps = (maxPenaltyBps * remainingDuration) / totalDuration;
        uint256 penalty = (principal * penaltyBps) / 10_000;

        uint256 treasuryFee = (penalty * treasuryFeeBps) / 10_000;

        uint256 toStakers = penalty - treasuryFee;

        uint256 remainingShares = totalShares - principal;

        if (remainingShares > 0) {
            uint256 delta = (toStakers * PRECISION) / remainingShares;
            accPenaltyPerShare += delta;
            emit PenaltyDistributed(toStakers, accPenaltyPerShare);
        } else {
            treasuryFee += toStakers;
        }

        totalShares -= principal;
        delete positions[_id];

        (bool sent,) = treasury.call{value: treasuryFee}("");
        if (!sent) revert TreasuryTransferFailed();

        (bool sentToOwner,) = owner.call{value: principal - penalty + reward}("");
        if (!sentToOwner) revert TransferFailed();

        emit Ragequit(_id, owner, penalty, principal - penalty + reward);
    }

    function harvestProfit(uint256 _id) public nonReentrant {
        Position storage p = positions[_id];
        address owner = p.owner;
        uint256 owed = pendingReward(_id);
        if (p.owner == address(0)) revert EmptyOwner();
        if (msg.sender != p.owner) revert NotOwner();
        if (owed == 0) revert NothingToHarvest();

        p.rewardDebt = (p.shares * accPenaltyPerShare) / PRECISION;

        (bool sentToOwner,) = owner.call{value: owed}("");
        if (!sentToOwner) revert TransferFailed();
        emit Harvested(_id, owner, owed);
    }
}
