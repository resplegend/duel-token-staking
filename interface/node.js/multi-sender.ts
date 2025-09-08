import {
  multiSenderAddress,
  tokenAddress,
  user1,
  user2,
} from "../constant/address";
import multiSenderABI from "../abi/multi-send.json";
import { privateKey, provider } from "../constant/constant";
import { Contract, Wallet, parseEther } from "ethers";

async function multiSend() {
  const signer: Wallet = new Wallet(privateKey, provider);

  const multiSender = new Contract(multiSenderAddress, multiSenderABI, signer);

  const tx = await multiSender["multiSend"](
    tokenAddress,
    [user1, user2],
    [parseEther("1000"), parseEther("1000")]
  );

  console.log("tx hash", tx.hash);

  const receipt = await tx.wait();

  console.log("tx", receipt);
}

multiSend();
