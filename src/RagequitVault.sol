// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
    uint constant PRECISION = 1e18;

    uint256 public nextId = 1;
    mapping(uint256 => Position) public positions;

    event Deposited(
        uint256 indexed id,
        address indexed owner,
        uint256 amount,
        uint256 duration
    );
    event Harvested(uint256 indexed id, address indexed owner, uint256 reward);
    event Ragequit(
        uint256 indexed id,
        address indexed owner,
        uint256 penalty,
        uint256 payout
    );
    event Withdrawn(
        uint256 indexed id,
        address indexed owner,
        uint256 principal,
        uint256 reward
    );
    event PenaltyDistributed(
        uint256 amountToStakers,
        uint256 accPenaltyPerShare
    );

    constructor(
        uint16 _maxPenaltyBps,
        uint16 _treasuryFeeBps,
        address _treasury
    ) {
        require(
            _maxPenaltyBps <= 10000,
            "You are asking for more penalty than the amount"
        );
        require(
            _treasuryFeeBps <= 10000,
            "You are asking for more treasury than amount"
        );
        require(_treasury != address(0), "Give the right address");
        maxPenaltyBps = _maxPenaltyBps;
        treasuryFeeBps = _treasuryFeeBps;
        treasury = _treasury;
    }

    function deposit(
        uint256 _durationSeconds
    ) external payable returns (uint256 id) {
        require(msg.value != 0, "Send something man");
        require(_durationSeconds != 0, "Give time more than 0 seconds");
        id = nextId++;
        Position storage people = positions[id];

        people.owner = msg.sender;
        people.shares = uint96(msg.value);
        people.start = block.timestamp;
        people.unlockAt = block.timestamp + _durationSeconds;

        people.rewardDebt =
            (uint256(people.shares) * accPenaltyPerShare) /
            PRECISION;

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

    function withdraw(uint256 _id) public {
        Position storage p = positions[_id];
        require(p.owner != address(0), "position does not exist");
        require(msg.sender == p.owner, "not position owner");
        require(block.timestamp >= p.unlockAt, "not yet mature");
        require(block.timestamp >= p.unlockAt, "your stake hasn't matured yet");

        uint96 principal = p.shares;
        uint256 reward = pendingReward(_id);
        totalShares -= p.shares;

        (bool sent, ) = p.owner.call{value: principal + reward}("");
        require(sent, "Failed to send Ether");

        emit Withdrawn(_id, p.owner, principal, reward);
        delete positions[_id];
    }
}
