import { ethers, upgrades } from "hardhat";

const usdc = "";
const maison = "";

async function main() {
  const Stake = await ethers.getContractFactory("DualTokenStaking");
  const stake = await upgrades.deployProxy(
    Stake,
    [usdc, maison, 1000, 30 * 86400, 180 * 86400],
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
