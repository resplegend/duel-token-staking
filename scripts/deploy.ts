import { ethers, upgrades } from "hardhat";

const stakeToken = "";
const rewardToken = "";

async function main() {
  const Stake = await ethers.getContractFactory("Stake");
  const stake = await upgrades.deployProxy(
    Stake,
    [stakeToken, rewardToken, 5 * 60, 1, 10000, 60 * 60, 1440 * 60],
    {
      initializer: "initialize",
    }
  );
  await stake.deployed();
  console.log("stake address", await stake.getAddress());
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
