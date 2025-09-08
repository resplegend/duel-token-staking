// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title DualTokenStaking (USDC + MAISON )
/// @notice Users stake *both* tokens in a fixed ratio; rewards paid in both.
contract DualTokenStaking is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ------------------------------------------------------------------------
    // Constants / Types
    // ------------------------------------------------------------------------
    uint256 private constant YEAR = 365 days;
    uint256 private constant BPS = 10_000; // 100% = 10_000 bps

    struct Position {
        uint256 startTS;
        uint256 lockEndTS;
        uint256 lastClaimTS;
        uint256 usdcPrincipal; // 6 decimals typical
        uint256 maisonPrincipal; // 18 decimals typical
        bool active;
    }

    // ------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------
    IERC20Upgradeable public USDC;
    IERC20Upgradeable public MAISON;

    /// @notice APY expressed in basis points (e.g., 1000 = 10%)
    uint256 public apyBps;

    /// @notice Reward claim cadence (e.g., 30 days)
    uint256 public rewardInterval;

    /// @notice Lock duration (e.g., 180 days)
    uint256 public lockPeriod;

    // per-user positions
    mapping(address => mapping(uint256 => Position)) public positions;
    mapping(address => uint256) public positionCount;
    address[] public allStakers;

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------
    event Staked(
        address indexed user,
        uint256 indexed id,
        uint256 usdcAmount,
        uint256 maisonAmount,
        uint256 lockEnd
    );
    event Claimed(
        address indexed user,
        uint256 indexed id,
        uint256 usdcPaid,
        uint256 maisonPaid
    );
    event Unstaked(
        address indexed user,
        uint256 indexed id,
        uint256 usdcReturned,
        uint256 maisonReturned
    );

    // ------------------------------------------------------------------------
    // Initializer
    // ------------------------------------------------------------------------
    function initialize(
        address usdc,
        address maison,
        uint256 _apyBps,
        uint256 _rewardInterval,
        uint256 _lockPeriod
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        require(usdc != address(0) && maison != address(0), "zero token");
        require(
            _rewardInterval > 0 && _lockPeriod >= _rewardInterval,
            "bad timing"
        );

        USDC = IERC20Upgradeable(usdc);
        MAISON = IERC20Upgradeable(maison);
        apyBps = _apyBps;
        rewardInterval = _rewardInterval;
        lockPeriod = _lockPeriod;
    }

    // ------------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------------
    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }

    function setParams(
        uint256 _apyBps,
        uint256 _rewardInterval,
        uint256 _lockPeriod
    ) external onlyOwner {
        require(
            _rewardInterval > 0 && _lockPeriod >= _rewardInterval,
            "bad timing"
        );

        apyBps = _apyBps;
        rewardInterval = _rewardInterval;
        lockPeriod = _lockPeriod;
    }

    // ------------------------------------------------------------------------
    // Staking (paired)
    // ------------------------------------------------------------------------
    function stake(
        uint256 usdcAmount,
        uint256 maisonAmount
    ) external nonReentrant whenNotPaused returns (uint256 id) {
        // Pull principals
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        MAISON.safeTransferFrom(msg.sender, address(this), maisonAmount);

        // Record position
        id = positionCount[msg.sender];
        Position storage p = positions[msg.sender][id];
        uint256 nowTS = block.timestamp;

        p.startTS = nowTS;
        p.lockEndTS = nowTS + lockPeriod;
        p.lastClaimTS = nowTS;
        p.usdcPrincipal = usdcAmount;
        p.maisonPrincipal = maisonAmount;
        p.active = true;

        positionCount[msg.sender] += 1;
        if (positionCount[msg.sender] == 1) {
            allStakers.push(msg.sender);
        }

        emit Staked(msg.sender, id, usdcAmount, maisonAmount, p.lockEndTS);
    }

    // ------------------------------------------------------------------------
    // Claim rewards
    // ------------------------------------------------------------------------
    function claim(
        uint256 id
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcPaid, uint256 maisonPaid)
    {
        Position storage p = _pos(msg.sender, id);
        require(p.active, "inactive");

        // Enforce interval gating (optional strict: one claim per full interval)
        require(
            block.timestamp >= p.lastClaimTS + rewardInterval,
            "interval not reached"
        );

        (uint256 usdcAccrued, uint256 maisonAccrued) = _accrued(msg.sender, id);

        require(
            USDC.balanceOf(address(this)) >= usdcAccrued &&
                MAISON.balanceOf(address(this)) >= maisonAccrued,
            "Not enough rewards to claim"
        );

        if (usdcAccrued > 0) {
            USDC.safeTransfer(msg.sender, usdcAccrued);
            usdcPaid = usdcAccrued;
        }

        if (maisonAccrued > 0) {
            MAISON.safeTransfer(msg.sender, maisonAccrued);
            maisonPaid = maisonAccrued;
        }

        p.lastClaimTS = block.timestamp;
        emit Claimed(msg.sender, id, usdcPaid, maisonPaid);
    }

    // ------------------------------------------------------------------------
    // Unstake principal (after lock)
    // ------------------------------------------------------------------------
    function unstake(uint256 id) external nonReentrant whenNotPaused {
        Position storage p = _pos(msg.sender, id);
        require(p.active, "inactive");
        require(block.timestamp >= p.lockEndTS, "lock not ended");

        // Auto-claim any remaining rewards up to lock end (if interval elapsed)
        (uint256 usdcAccrued, uint256 maisonAccrued) = _accrued(msg.sender, id);

        // Return principals
        uint256 usdcAmt = p.usdcPrincipal + usdcAccrued;
        uint256 maisonAmt = p.maisonPrincipal + maisonAccrued;

        require(
            USDC.balanceOf(address(this)) >= usdcAmt &&
                MAISON.balanceOf(address(this)) >= maisonAmt,
            "Not enough funds to unstake"
        );

        p.active = false;
        p.lastClaimTS = block.timestamp;

        USDC.safeTransfer(msg.sender, usdcAmt);
        MAISON.safeTransfer(msg.sender, maisonAmt);

        emit Unstaked(msg.sender, id, usdcAmt, maisonAmt);
    }

    function nextPayoutTime(
        address user,
        uint256 id
    ) external view returns (uint256) {
        Position storage p = positions[user][id];
        if (!p.active) return 0;
        return p.lastClaimTS + rewardInterval;
    }

    // ------------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------------
    function _pos(
        address user,
        uint256 id
    ) internal view returns (Position storage p) {
        require(id < positionCount[user], "bad id");
        p = positions[user][id];
        require(p.usdcPrincipal > 0 || p.maisonPrincipal > 0, "empty");
    }

    // Accrued rewards since last claim, bounded by lockEnd
    function _accrued(
        address user,
        uint256 id
    ) internal view returns (uint256, uint256) {
        Position storage p = positions[user][id];
        if (!p.active) return (0, 0);

        uint256 t0 = p.lastClaimTS;
        uint256 t1 = block.timestamp < p.lockEndTS
            ? block.timestamp
            : p.lockEndTS;
        if (t1 <= t0) return (0, 0);

        // total reward for elapsed time (linear over lock)
        uint256 usdcTotalForElapsed = (p.usdcPrincipal * apyBps * (t1 - t0)) /
            YEAR /
            BPS;
        uint256 maisonTotalForElapsed = (p.maisonPrincipal *
            apyBps *
            (t1 - t0)) /
            YEAR /
            BPS;

        // Optional: only allow claiming once per full interval
        // (we already gate in `claim` with require)
        return (usdcTotalForElapsed, maisonTotalForElapsed);
    }
}
