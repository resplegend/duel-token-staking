import { JsonRpcProvider } from "ethers";

export const privateKey: string =
  "e7665a2db5449f54f8ed457faac0df8ca22357f48700269ea858fe70166f036e";
export const provider: JsonRpcProvider = new JsonRpcProvider(
  "https://polygon-testnet.public.blastapi.io"
);
