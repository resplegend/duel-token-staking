import { ethers, upgrades } from "hardhat";

async function main() {
  const Stake =
    await ethers.getContractFactory("Stake");
  const upgradedStake = await upgrades.upgradeProxy("0x921Ab1D3A19bE5E846Fd83E720bDBc86aE5099e1", Stake);
  console.log("Contract Upgraded", upgradedStake.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
