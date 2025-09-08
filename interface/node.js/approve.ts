import { parseEther, parseUnits, Contract, Wallet } from "ethers";
import { stakeAddress, tokenAddress } from "../constant/address";
import acemABI from "../abi/acem.json";
import { privateKey, provider } from "../constant/constant";

async function approve() {
  const signer: Wallet = new Wallet(privateKey, provider);

  const acem = new Contract(tokenAddress, acemABI, signer);

  const tx = await acem["approve"](stakeAddress, parseEther("5000"), {
    gasPrice: parseUnits("3", "gwei"),
  });
  console.log("tx hash", tx.hash);
  const receipt = await tx.wait();

  console.log("tx", receipt);
}

approve();
