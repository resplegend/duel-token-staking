# DualTokenStaking Contract

A Solidity smart contract that allows users to stake both USDC and MAISON tokens in a fixed ratio, with rewards paid in both tokens. The contract uses an oracle to determine the MAISON price for maintaining the correct staking ratio.

## Features

- **Dual Token Staking**: Users must stake both USDC and MAISON tokens in a fixed ratio
- **Oracle-Based Pricing**: Uses an external oracle to determine MAISON price for ratio calculation
- **Time-Locked Staking**: Tokens are locked for a configurable period
- **Periodic Rewards**: Users can claim rewards at regular intervals
- **Upgradeable**: Built with OpenZeppelin's upgradeable contracts
- **Pausable**: Admin can pause/unpause the contract in emergencies
- **Reentrancy Protection**: Protected against reentrancy attacks

## Contract Architecture

### Core Components

- **DualTokenStaking**: Main staking contract (upgradeable)
- **IOracle**: Interface for price oracle integration
- **MockERC20**: Test tokens for USDC and MAISON
- **MockOracle**: Test oracle for price feeds

### Key Functions

#### Staking
- `stake(uint256 usdcAmount)`: Stake USDC and corresponding MAISON amount
- Users must approve the contract to spend their tokens first

#### Rewards
- `claim(uint256 id)`: Claim accrued rewards for a position
- Rewards are calculated based on APY and time elapsed
- Can only claim once per reward interval

#### Unstaking
- `unstake(uint256 id)`: Unstake tokens after lock period
- Automatically claims any remaining rewards
- Returns both principal and accrued rewards

#### Admin Functions
- `setParams(uint256 _apyBps, uint256 _rewardInterval, uint256 _lockPeriod)`: Update contract parameters
- `pause()` / `unpause()`: Emergency pause functionality

## Configuration

### Parameters
- **APY**: Annual Percentage Yield in basis points (e.g., 1000 = 10%)
- **Reward Interval**: Time between allowed reward claims (e.g., 30 days)
- **Lock Period**: Minimum staking duration (e.g., 180 days)

### Token Decimals
- **USDC**: 6 decimals (standard)
- **MAISON**: 18 decimals (standard)

## Installation & Setup

### Prerequisites
- Node.js (v16+ recommended)
- Yarn or npm
- Hardhat

### Installation
```bash
# Install dependencies
yarn install

# Compile contracts
npx hardhat compile

# Run tests
npx hardhat test

# Run specific test file
npx hardhat test test/Stake.test.ts
```

## Testing

The project includes comprehensive tests covering:

### Stake Function Tests
- ✅ Successful staking with correct token amounts
- ✅ Proper MAISON amount calculation based on oracle price
- ✅ Error handling for zero oracle price
- ✅ Insufficient balance scenarios
- ✅ Paused contract behavior
- ✅ Multiple positions per user

### Claim Function Tests
- ✅ Successful reward claiming after interval
- ✅ Error handling for premature claiming
- ✅ Inactive position handling
- ✅ Insufficient rewards in contract
- ✅ Paused contract behavior

### Unstake Function Tests
- ✅ Successful unstaking after lock period
- ✅ Error handling for premature unstaking
- ✅ Inactive position handling
- ✅ Insufficient contract funds
- ✅ Auto-claiming of remaining rewards

### Integration Tests
- ✅ Complete staking lifecycle (stake → claim → unstake)
- ✅ Multiple users staking simultaneously

## Usage Examples

### Staking Tokens
```solidity
// Approve tokens first
usdc.approve(stakingContract, amount);
maison.approve(stakingContract, amount);

// Stake USDC (MAISON amount calculated automatically)
uint256 positionId = stakingContract.stake(usdcAmount);
```

### Claiming Rewards
```solidity
// Wait for reward interval, then claim
stakingContract.claim(positionId);
```

### Unstaking
```solidity
// Wait for lock period, then unstake
stakingContract.unstake(positionId);
```

## Security Features

- **ReentrancyGuard**: Prevents reentrancy attacks
- **Pausable**: Emergency stop functionality
- **Access Control**: Owner-only admin functions
- **SafeERC20**: Safe token transfer operations
- **Input Validation**: Comprehensive parameter validation

## Deployment

### Local Development
```bash
# Start local node
npx hardhat node

# Deploy to local network
npx hardhat run scripts/deploy.ts --network localhost
```

### Testnet Deployment
```bash
# Deploy to Polygon Mumbai
npx hardhat run scripts/deploy.ts --network polygon_mumbai
```

## Contract Addresses

*Update with actual deployed addresses*

- **DualTokenStaking**: `TBD`
- **USDC**: `TBD`
- **MAISON**: `TBD`
- **Oracle**: `TBD`

## Gas Optimization

The contract is optimized for gas efficiency:
- Packed structs for storage optimization
- Minimal external calls
- Efficient reward calculations
- Batch operations where possible

## Risk Considerations

- **Oracle Risk**: Contract depends on oracle for price feeds
- **Smart Contract Risk**: Code is audited but risks remain
- **Market Risk**: Token prices can fluctuate
- **Liquidity Risk**: Contract must maintain sufficient rewards

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass
6. Submit a pull request

## License

MIT License - see LICENSE file for details

## Support

For questions or issues:
- Create an issue in the repository
- Contact the development team

## Changelog

### v1.0.0
- Initial release
- Core staking functionality
- Oracle integration
- Comprehensive test suite
- Upgradeable contract architecture