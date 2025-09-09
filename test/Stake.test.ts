import { expect } from "chai";
import { ethers } from "hardhat";
import { Signer } from "ethers";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { DualTokenStaking, MockERC20, MockOracle } from "../typechain-types";

describe("DualTokenStaking - Core Functions", function () {
  let dualTokenStaking: DualTokenStaking;
  let usdc: MockERC20;
  let maison: MockERC20;
  let oracle: MockOracle;
  let owner: Signer;
  let user1: Signer;
  let user2: Signer;
  let ownerAddress: string;
  let user1Address: string;
  let user2Address: string;

  // Test constants
  const USDC_DECIMALS = 6;
  const MAISON_DECIMALS = 18;
  const APY_BPS = 1000; // 10%
  const REWARD_INTERVAL = 30 * 24 * 60 * 60; // 30 days
  const LOCK_PERIOD = 180 * 24 * 60 * 60; // 180 days
  const MAISON_PRICE = ethers.parseEther("0.5"); // $0.5 per MAISON

  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();
    ownerAddress = await owner.getAddress();
    user1Address = await user1.getAddress();
    user2Address = await user2.getAddress();

    // Deploy Mock USDC (6 decimals)
    const MockUSDC = await ethers.getContractFactory("MockERC20");
    usdc = await MockUSDC.deploy("USD Coin", "USDC", USDC_DECIMALS);
    await usdc.waitForDeployment();

    // Deploy Mock MAISON (18 decimals)
    const MockMAISON = await ethers.getContractFactory("MockERC20");
    maison = await MockMAISON.deploy("Maison Token", "MAISON", MAISON_DECIMALS);
    await maison.waitForDeployment();

    // Deploy Mock Oracle
    const MockOracle = await ethers.getContractFactory("MockOracle");
    oracle = await MockOracle.deploy(MAISON_PRICE);
    await oracle.waitForDeployment();

    // Deploy DualTokenStaking
    const DualTokenStaking = await ethers.getContractFactory("DualTokenStaking");
    dualTokenStaking = await DualTokenStaking.deploy();
    await dualTokenStaking.waitForDeployment();

    // Initialize the contract
    await dualTokenStaking.initialize(
      await usdc.getAddress(),
      await maison.getAddress(),
      await oracle.getAddress(),
      APY_BPS,
      REWARD_INTERVAL,
      LOCK_PERIOD
    );

    // Mint tokens to users
    const usdcAmount = ethers.parseUnits("10000", USDC_DECIMALS);
    const maisonAmount = ethers.parseEther("20000");

    await usdc.mint(user1Address, usdcAmount);
    await usdc.mint(user2Address, usdcAmount);
    await maison.mint(user1Address, maisonAmount);
    await maison.mint(user2Address, maisonAmount);

    // Approve staking contract to spend tokens
    await usdc.connect(user1).approve(await dualTokenStaking.getAddress(), ethers.MaxUint256);
    await maison.connect(user1).approve(await dualTokenStaking.getAddress(), ethers.MaxUint256);
    await usdc.connect(user2).approve(await dualTokenStaking.getAddress(), ethers.MaxUint256);
    await maison.connect(user2).approve(await dualTokenStaking.getAddress(), ethers.MaxUint256);

    // Fund the contract with rewards
    const rewardAmount = ethers.parseUnits("10000", USDC_DECIMALS);
    const maisonRewardAmount = ethers.parseEther("20000");
    await usdc.mint(await dualTokenStaking.getAddress(), rewardAmount);
    await maison.mint(await dualTokenStaking.getAddress(), maisonRewardAmount);
  });

  describe("Stake Function", function () {
    it("Should successfully stake USDC and MAISON tokens", async function () {
      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      const expectedMaisonAmount = (usdcAmount * ethers.parseEther("1")) / MAISON_PRICE;

      const tx = await dualTokenStaking.connect(user1).stake(usdcAmount);
      const receipt = await tx.wait();

      // Check events
      const stakedEvent = receipt!.logs.find(log => {
        try {
          const parsed = dualTokenStaking.interface.parseLog(log as any);
          return parsed?.name === "Staked";
        } catch {
          return false;
        }
      });

      expect(stakedEvent).to.not.be.undefined;

      // Check position data
      const position = await dualTokenStaking.positions(user1Address, 0);
      expect(position.active).to.be.true;
      expect(position.usdcPrincipal).to.equal(usdcAmount);
      expect(position.maisonPrincipal).to.equal(expectedMaisonAmount);
      expect(position.startTS).to.be.greaterThan(0);
      expect(position.lockEndTS).to.equal(position.startTS + BigInt(LOCK_PERIOD));

      // Check position count
      expect(await dualTokenStaking.positionCount(user1Address)).to.equal(1);

      // Check allStakers array
      expect(await dualTokenStaking.allStakers(0)).to.equal(user1Address);
    });

    it("Should calculate correct MAISON amount based on oracle price", async function () {
      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      const expectedMaisonAmount = (usdcAmount * ethers.parseEther("1")) / MAISON_PRICE;

      await dualTokenStaking.connect(user1).stake(usdcAmount);

      const position = await dualTokenStaking.positions(user1Address, 0);
      expect(position.maisonPrincipal).to.equal(expectedMaisonAmount);
    });

    it("Should revert when oracle returns zero price", async function () {
      // Set oracle to return zero price
      await oracle.setPrice(0);

      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);

      await expect(
        dualTokenStaking.connect(user1).stake(usdcAmount)
      ).to.be.revertedWith("Invalid price");
    });

    it("Should revert when user has insufficient USDC balance", async function () {
      const usdcAmount = ethers.parseUnits("50000", USDC_DECIMALS); // More than user has

      await expect(
        dualTokenStaking.connect(user1).stake(usdcAmount)
      ).to.be.revertedWith("ERC20: transfer amount exceeds balance");
    });

    it("Should revert when user has insufficient MAISON balance", async function () {
      // Set extremely low price so required MAISON amount becomes huge
      await oracle.setPrice(1n); // 1 wei per MAISON
      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);

      await expect(
        dualTokenStaking.connect(user1).stake(usdcAmount)
      ).to.be.revertedWith("ERC20: transfer amount exceeds balance");
    });

    it("Should revert when contract is paused", async function () {
      await dualTokenStaking.connect(owner).pause();

      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);

      await expect(
        dualTokenStaking.connect(user1).stake(usdcAmount)
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should allow multiple positions per user", async function () {
      const usdcAmount1 = ethers.parseUnits("1000", USDC_DECIMALS);
      const usdcAmount2 = ethers.parseUnits("500", USDC_DECIMALS);

      await dualTokenStaking.connect(user1).stake(usdcAmount1);
      await dualTokenStaking.connect(user1).stake(usdcAmount2);

      expect(await dualTokenStaking.positionCount(user1Address)).to.equal(2);

      const position1 = await dualTokenStaking.positions(user1Address, 0);
      const position2 = await dualTokenStaking.positions(user1Address, 1);

      expect(position1.usdcPrincipal).to.equal(usdcAmount1);
      expect(position2.usdcPrincipal).to.equal(usdcAmount2);
    });
  });

  describe("Claim Function", function () {
    beforeEach(async function () {
      // Stake some tokens first
      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      await dualTokenStaking.connect(user1).stake(usdcAmount);
    });

    it("Should successfully claim rewards after interval", async function () {
      // Fast forward past reward interval
      await time.increase(REWARD_INTERVAL + 1);

      // Add some rewards to the contract
      const rewardAmount = ethers.parseUnits("100", USDC_DECIMALS);
      await usdc.mint(await dualTokenStaking.getAddress(), rewardAmount);
      await maison.mint(await dualTokenStaking.getAddress(), ethers.parseEther("200"));

      const tx = await dualTokenStaking.connect(user1).claim(0);
      const receipt = await tx.wait();

      // Check events
      const claimedEvent = receipt!.logs.find(log => {
        try {
          const parsed = dualTokenStaking.interface.parseLog(log as any);
          return parsed?.name === "Claimed";
        } catch {
          return false;
        }
      });

      expect(claimedEvent).to.not.be.undefined;

      // Check that lastClaimTS was updated
      const position = await dualTokenStaking.positions(user1Address, 0);
      expect(position.lastClaimTS).to.be.greaterThan(position.startTS);
    });

    it("Should revert when trying to claim before interval", async function () {
      await expect(
        dualTokenStaking.connect(user1).claim(0)
      ).to.be.revertedWith("interval not reached");
    });

    it("Should revert when position is inactive", async function () {
      // Fast forward past lock period and unstake
      await time.increase(LOCK_PERIOD + 1);
      await dualTokenStaking.connect(user1).unstake(0);

      await time.increase(REWARD_INTERVAL + 1);

      await expect(
        dualTokenStaking.connect(user1).claim(0)
      ).to.be.revertedWith("inactive");
    });

    it("Should revert when contract has insufficient rewards", async function () {
      await time.increase(REWARD_INTERVAL + 1);

      // Burn all rewards from the contract to simulate insufficient rewards
      const contractAddr = await dualTokenStaking.getAddress();
      const usdcBal = await usdc.balanceOf(contractAddr);
      const maisonBal = await maison.balanceOf(contractAddr);
      if (usdcBal > 0n) {
        await usdc.burn(contractAddr, usdcBal);
      }
      if (maisonBal > 0n) {
        await maison.burn(contractAddr, maisonBal);
      }

      await expect(
        dualTokenStaking.connect(user1).claim(0)
      ).to.be.revertedWith("Not enough rewards to claim");
    });

    it("Should revert when contract is paused", async function () {
      await time.increase(REWARD_INTERVAL + 1);
      await dualTokenStaking.connect(owner).pause();

      await expect(
        dualTokenStaking.connect(user1).claim(0)
      ).to.be.revertedWith("Pausable: paused");
    });
  });

  describe("Unstake Function", function () {
    beforeEach(async function () {
      // Stake some tokens first
      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      await dualTokenStaking.connect(user1).stake(usdcAmount);
    });

    it("Should successfully unstake after lock period", async function () {
      // Fast forward past lock period
      await time.increase(LOCK_PERIOD + 1);

      const user1BalanceBefore = await usdc.balanceOf(user1Address);
      const maisonBalanceBefore = await maison.balanceOf(user1Address);

      const tx = await dualTokenStaking.connect(user1).unstake(0);
      const receipt = await tx.wait();

      // Check events
      const unstakedEvent = receipt!.logs.find(log => {
        try {
          const parsed = dualTokenStaking.interface.parseLog(log as any);
          return parsed?.name === "Unstaked";
        } catch {
          return false;
        }
      });

      expect(unstakedEvent).to.not.be.undefined;

      // Check that position is now inactive
      const position = await dualTokenStaking.positions(user1Address, 0);
      expect(position.active).to.be.false;

      // Check that user received their tokens back
      const user1BalanceAfter = await usdc.balanceOf(user1Address);
      const maisonBalanceAfter = await maison.balanceOf(user1Address);

      expect(user1BalanceAfter).to.be.greaterThan(user1BalanceBefore);
      expect(maisonBalanceAfter).to.be.greaterThan(maisonBalanceBefore);
    });

    it("Should revert when trying to unstake before lock period", async function () {
      await expect(
        dualTokenStaking.connect(user1).unstake(0)
      ).to.be.revertedWith("lock not ended");
    });

    it("Should revert when position is inactive", async function () {
      await time.increase(LOCK_PERIOD + 1);
      await dualTokenStaking.connect(user1).unstake(0);

      await expect(
        dualTokenStaking.connect(user1).unstake(0)
      ).to.be.revertedWith("inactive");
    });

    it("Should revert when contract has insufficient funds", async function () {
      await time.increase(LOCK_PERIOD + 1);

      // Get the position to know how much to leave
      const position = await dualTokenStaking.positions(user1Address, 0);
      const usdcNeeded = position.usdcPrincipal;
      const maisonNeeded = position.maisonPrincipal;

      // Burn so that balances are just below required amounts
      const contractAddr2 = await dualTokenStaking.getAddress();
      const usdcBalance = await usdc.balanceOf(contractAddr2);
      const maisonBalance = await maison.balanceOf(contractAddr2);
      if (usdcBalance > usdcNeeded) {
        await usdc.burn(contractAddr2, usdcBalance - usdcNeeded + 1n);
      }
      if (maisonBalance > maisonNeeded) {
        await maison.burn(contractAddr2, maisonBalance - maisonNeeded + 1n);
      }

      await expect(
        dualTokenStaking.connect(user1).unstake(0)
      ).to.be.revertedWith("Not enough funds to unstake");
    });

    it("Should revert when contract is paused", async function () {
      await time.increase(LOCK_PERIOD + 1);
      await dualTokenStaking.connect(owner).pause();

      await expect(
        dualTokenStaking.connect(user1).unstake(0)
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should auto-claim remaining rewards when unstaking", async function () {
      // Fast forward past lock period
      await time.increase(LOCK_PERIOD + 1);

      // Add some rewards to the contract
      const rewardAmount = ethers.parseUnits("100", USDC_DECIMALS);
      await usdc.mint(await dualTokenStaking.getAddress(), rewardAmount);
      await maison.mint(await dualTokenStaking.getAddress(), ethers.parseEther("200"));

      const user1BalanceBefore = await usdc.balanceOf(user1Address);
      const maisonBalanceBefore = await maison.balanceOf(user1Address);

      await dualTokenStaking.connect(user1).unstake(0);

      const user1BalanceAfter = await usdc.balanceOf(user1Address);
      const maisonBalanceAfter = await maison.balanceOf(user1Address);

      // User should receive more than just their principal (including rewards)
      expect(user1BalanceAfter - user1BalanceBefore).to.be.greaterThan(ethers.parseUnits("1000", USDC_DECIMALS));
      expect(maisonBalanceAfter - maisonBalanceBefore).to.be.greaterThan(0);
    });
  });

  describe("Integration Tests", function () {
    it("Should handle complete staking lifecycle", async function () {
      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      const expectedMaisonAmount = (usdcAmount * ethers.parseEther("1")) / MAISON_PRICE;

      // 1. Stake
      await dualTokenStaking.connect(user1).stake(usdcAmount);
      
      const position = await dualTokenStaking.positions(user1Address, 0);
      expect(position.active).to.be.true;

      // 2. Wait for reward interval and claim
      await time.increase(REWARD_INTERVAL + 1);
      
      // Add rewards to contract
      await usdc.mint(await dualTokenStaking.getAddress(), ethers.parseUnits("100", USDC_DECIMALS));
      await maison.mint(await dualTokenStaking.getAddress(), ethers.parseEther("200"));

      await dualTokenStaking.connect(user1).claim(0);

      // 3. Wait for lock period and unstake
      await time.increase(LOCK_PERIOD - REWARD_INTERVAL + 1);
      
      await dualTokenStaking.connect(user1).unstake(0);

      const finalPosition = await dualTokenStaking.positions(user1Address, 0);
      expect(finalPosition.active).to.be.false;
    });

    it("Should handle multiple users staking simultaneously", async function () {
      const usdcAmount1 = ethers.parseUnits("1000", USDC_DECIMALS);
      const usdcAmount2 = ethers.parseUnits("500", USDC_DECIMALS);

      await dualTokenStaking.connect(user1).stake(usdcAmount1);
      await dualTokenStaking.connect(user2).stake(usdcAmount2);

      expect(await dualTokenStaking.positionCount(user1Address)).to.equal(1);
      expect(await dualTokenStaking.positionCount(user2Address)).to.equal(1);
      expect(await dualTokenStaking.allStakers(0)).to.equal(user1Address);
      expect(await dualTokenStaking.allStakers(1)).to.equal(user2Address);
    });
  });
});
