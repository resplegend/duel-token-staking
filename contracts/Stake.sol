// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title DualTokenStaking (USDC + MAISON) — fixed APY, time-locked, guaranteed rewards
/// @notice Users stake *both* tokens in a fixed ratio; rewards paid in both.
///         Contract requires pre-funding (or periodic top ups) and reserves
///         reward obligations at stake time so later claims cannot fail.
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
    uint256 private constant BPS = 10_000;    // 100% = 10_000 bps
    uint256 private constant ONE = 1e18;      // fixed-point for ratios

    struct Position {
        uint256 startTS;
        uint256 lockEndTS;
        uint256 lastClaimTS;

        uint256 usdcPrincipal;    // 6 decimals typical
        uint256 maisonPrincipal;  // 18 decimals typical

        // Reward accounting (guaranteed approach):
        uint256 usdcRewardObligation;   // total reward owed over full lock
        uint256 maisonRewardObligation; // total reward owed over full lock
        uint256 usdcRewardClaimed;      // lifetime claimed
        uint256 maisonRewardClaimed;    // lifetime claimed

        bool    active;
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

    /// @notice Required MAISON per 1 USDC (scaled by 1e18). Example: 103.8e18
    uint256 public maisonPerUsdc;

    // Reward pool reservation (sum of all active unclaimed obligations)
    uint256 public reservedUSDC;
    uint256 public reservedMAISON;

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
    event Funded(uint256 usdcAdded, uint256 maisonAdded);
    event ParamsUpdated(uint256 apyBps, uint256 rewardInterval, uint256 lockPeriod, uint256 maisonPerUsdc);

    // ------------------------------------------------------------------------
    // Initializer
    // ------------------------------------------------------------------------
    function initialize(
        address usdc,
        address maison,
        uint256 _apyBps,
        uint256 _rewardInterval,
        uint256 _lockPeriod,
        uint256 _maisonPerUsdc // 1e18 precision
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        require(usdc != address(0) && maison != address(0), "zero token");
        require(_rewardInterval > 0 && _lockPeriod >= _rewardInterval, "bad timing");
        require(_maisonPerUsdc > 0, "bad ratio");

        USDC = IERC20Upgradeable(usdc);
        MAISON = IERC20Upgradeable(maison);
        apyBps = _apyBps;
        rewardInterval = _rewardInterval;
        lockPeriod = _lockPeriod;
        maisonPerUsdc = _maisonPerUsdc;
    }

    // ------------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------------
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setParams(
        uint256 _apyBps,
        uint256 _rewardInterval,
        uint256 _lockPeriod,
        uint256 _maisonPerUsdc
    ) external onlyOwner {
        require(_apyBps <= 5000, "APY too high");
        require(_rewardInterval > 0 && _lockPeriod >= _rewardInterval, "bad timing");
        require(_maisonPerUsdc > 0, "bad ratio");

        apyBps = _apyBps;
        rewardInterval = _rewardInterval;
        lockPeriod = _lockPeriod;
        maisonPerUsdc = _maisonPerUsdc;

        emit ParamsUpdated(_apyBps, _rewardInterval, _lockPeriod, _maisonPerUsdc);
    }

    /// @notice Owner funds rewards. Must `approve` this contract first for both tokens if passing >0.
    function fundRewards(uint256 usdcAmount, uint256 maisonAmount) external onlyOwner {
        if (usdcAmount > 0) USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        if (maisonAmount > 0) MAISON.safeTransferFrom(msg.sender, address(this), maisonAmount);
        emit Funded(usdcAmount, maisonAmount);
    }

    /// @notice Optional: allow owner to withdraw *excess* rewards above reservations.
    function withdrawExcess(uint256 usdcAmount, uint256 maisonAmount) external onlyOwner {
        require(USDC.balanceOf(address(this)) >= reservedUSDC + usdcAmount, "insufficient USDC");
        require(MAISON.balanceOf(address(this)) >= reservedMAISON + maisonAmount, "insufficient MAISON");
        if (usdcAmount > 0) USDC.safeTransfer(owner(), usdcAmount);
        if (maisonAmount > 0) MAISON.safeTransfer(owner(), maisonAmount);
    }

    // ------------------------------------------------------------------------
    // Staking (paired)
    // ------------------------------------------------------------------------
    function stake(uint256 usdcAmount, uint256 maisonAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        require(usdcAmount > 0, "zero USDC");

        // Enforce pair ratio (allow 1 wei slack for rounding on 6 vs 18 decimals)
        uint256 requiredMaison = (usdcAmount * maisonPerUsdc) / ONE;
        require(
            maisonAmount + 1 >= requiredMaison && maisonAmount <= requiredMaison + 1,
            "bad MAISON amount for ratio"
        );

        // Compute *total reward obligation* for full lock
        // Linear accrual: principal * apyBps * lockPeriod / YEAR / BPS
        uint256 usdcObligation =
            (usdcAmount * apyBps * lockPeriod) / YEAR / BPS;
        uint256 maisonObligation =
            (maisonAmount * apyBps * lockPeriod) / YEAR / BPS;

        // Guarantee funding: require balances exceed existing reservations + new obligation
        require(USDC.balanceOf(address(this)) >= reservedUSDC + usdcObligation, "insufficient USDC rewards");
        require(MAISON.balanceOf(address(this)) >= reservedMAISON + maisonObligation, "insufficient MAISON rewards");

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
        p.usdcRewardObligation = usdcObligation;
        p.maisonRewardObligation = maisonObligation;
        p.usdcRewardClaimed = 0;
        p.maisonRewardClaimed = 0;
        p.active = true;

        positionCount[msg.sender] += 1;
        if (positionCount[msg.sender] == 1) {
            allStakers.push(msg.sender);
        }

        // Reserve obligations
        reservedUSDC += usdcObligation;
        reservedMAISON += maisonObligation;

        emit Staked(msg.sender, id, usdcAmount, maisonAmount, p.lockEndTS);
    }

    // ------------------------------------------------------------------------
    // Claim rewards
    // ------------------------------------------------------------------------
    function claim(uint256 id) external nonReentrant whenNotPaused returns (uint256 usdcPaid, uint256 maisonPaid) {
        Position storage p = _pos(msg.sender, id);
        require(p.active, "inactive");

        // Enforce interval gating (optional strict: one claim per full interval)
        require(block.timestamp >= p.lastClaimTS + rewardInterval, "interval not reached");

        (uint256 usdcAccrued, uint256 maisonAccrued) = _accrued(msg.sender, id);

        if (usdcAccrued > 0) {
            p.usdcRewardClaimed += usdcAccrued;
            reservedUSDC -= usdcAccrued;
            USDC.safeTransfer(msg.sender, usdcAccrued);
            usdcPaid = usdcAccrued;
        }

        if (maisonAccrued > 0) {
            p.maisonRewardClaimed += maisonAccrued;
            reservedMAISON -= maisonAccrued;
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
        (uint256 usdcAccrued, uint256 maisonAccrued) = _accruedUpTo(msg.sender, id, p.lockEndTS);
        if (usdcAccrued > 0) {
            p.usdcRewardClaimed += usdcAccrued;
            reservedUSDC -= usdcAccrued;
            USDC.safeTransfer(msg.sender, usdcAccrued);
        }
        if (maisonAccrued > 0) {
            p.maisonRewardClaimed += maisonAccrued;
            reservedMAISON -= maisonAccrued;
            MAISON.safeTransfer(msg.sender, maisonAccrued);
        }

        // Return principals
        uint256 usdcAmt = p.usdcPrincipal;
        uint256 maisonAmt = p.maisonPrincipal;

        p.active = false;
        p.lastClaimTS = block.timestamp;

        USDC.safeTransfer(msg.sender, usdcAmt);
        MAISON.safeTransfer(msg.sender, maisonAmt);

        emit Unstaked(msg.sender, id, usdcAmt, maisonAmt);
    }

    // ------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------
    function getStake(address user, uint256 id) external view returns (Position memory) {
        return positions[user][id];
    }

    function earned(address user, uint256 id) external view returns (uint256 usdcEarned, uint256 maisonEarned) {
        return _accrued(user, id);
    }

    function canUnstake(address user, uint256 id) external view returns (bool) {
        Position storage p = positions[user][id];
        return p.active && block.timestamp >= p.lockEndTS;
    }

    function nextPayoutTime(address user, uint256 id) external view returns (uint256) {
        Position storage p = positions[user][id];
        if (!p.active) return 0;
        return p.lastClaimTS + rewardInterval;
    }

    function totalStakedUSDC() external view returns (uint256 total) {
        for (uint256 i=0; i<allStakers.length; i++) {
            address u = allStakers[i];
            uint256 n = positionCount[u];
            for (uint256 j=0; j<n; j++) {
                Position storage p = positions[u][j];
                if (p.active) total += p.usdcPrincipal;
            }
        }
    }

    function totalStakedMaison() external view returns (uint256 total) {
        for (uint256 i=0; i<allStakers.length; i++) {
            address u = allStakers[i];
            uint256 n = positionCount[u];
            for (uint256 j=0; j<n; j++) {
                Position storage p = positions[u][j];
                if (p.active) total += p.maisonPrincipal;
            }
        }
    }

    function rewardPoolBalances() external view returns (uint256 usdcBal, uint256 maisonBal, uint256 usdcRes, uint256 maisonRes) {
        return (USDC.balanceOf(address(this)), MAISON.balanceOf(address(this)), reservedUSDC, reservedMAISON);
    }

    // ------------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------------
    function _pos(address user, uint256 id) internal view returns (Position storage p) {
        require(id < positionCount[user], "bad id");
        p = positions[user][id];
        require(p.usdcPrincipal > 0 || p.maisonPrincipal > 0, "empty");
    }

    // Accrued rewards since last claim, bounded by lockEnd
    function _accrued(address user, uint256 id) internal view returns (uint256, uint256) {
        Position storage p = positions[user][id];
        if (!p.active) return (0, 0);

        uint256 t0 = p.lastClaimTS;
        uint256 t1 = block.timestamp < p.lockEndTS ? block.timestamp : p.lockEndTS;
        if (t1 <= t0) return (0, 0);

        // total reward for elapsed time (linear over lock)
        uint256 usdcTotalForElapsed =
            (p.usdcPrincipal * apyBps * (t1 - t0)) / YEAR / BPS;
        uint256 maisonTotalForElapsed =
            (p.maisonPrincipal * apyBps * (t1 - t0)) / YEAR / BPS;

        // Don’t exceed remaining obligations
        uint256 usdcRemaining = p.usdcRewardObligation - p.usdcRewardClaimed;
        uint256 maisonRemaining = p.maisonRewardObligation - p.maisonRewardClaimed;

        if (usdcTotalForElapsed > usdcRemaining) usdcTotalForElapsed = usdcRemaining;
        if (maisonTotalForElapsed > maisonRemaining) maisonTotalForElapsed = maisonRemaining;

        // Optional: only allow claiming once per full interval
        // (we already gate in `claim` with require)
        return (usdcTotalForElapsed, maisonTotalForElapsed);
    }

    // Accrued up to a custom cutoff (used for unstake to lockEndTS)
    function _accruedUpTo(address user, uint256 id, uint256 cutoff)
        internal
        view
        returns (uint256, uint256)
    {
        Position storage p = positions[user][id];
        if (!p.active) return (0, 0);

        uint256 t0 = p.lastClaimTS;
        uint256 t1 = cutoff < p.lockEndTS ? cutoff : p.lockEndTS;
        if (t1 <= t0) return (0, 0);

        uint256 usdcAmt =
            (p.usdcPrincipal * apyBps * (t1 - t0)) / YEAR / BPS;
        uint256 maisonAmt =
            (p.maisonPrincipal * apyBps * (t1 - t0)) / YEAR / BPS;

        uint256 usdcRemaining = p.usdcRewardObligation - p.usdcRewardClaimed;
        uint256 maisonRemaining = p.maisonRewardObligation - p.maisonRewardClaimed;

        if (usdcAmt > usdcRemaining) usdcAmt = usdcRemaining;
        if (maisonAmt > maisonRemaining) maisonAmt = maisonRemaining;

        return (usdcAmt, maisonAmt);
    }
}
