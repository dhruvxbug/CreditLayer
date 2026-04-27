"use client";

import { ReactNode, useState } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RainbowKitProvider, getDefaultConfig } from "@rainbow-me/rainbowkit";
import "@rainbow-me/rainbowkit/styles.css";
import { createConfig, http, WagmiProvider } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { injected } from "wagmi/connectors";

const walletConnectProjectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID;
const chains = [baseSepolia] as const;

const wagmiConfig = walletConnectProjectId
  ? getDefaultConfig({
      appName: "CreditLayer",
      projectId: walletConnectProjectId,
      chains,
      ssr: true,
    })
  : createConfig({
      chains,
      connectors: [injected()],
      transports: {
        [baseSepolia.id]: http(process.env.NEXT_PUBLIC_BASE_RPC_URL),
      },
      ssr: true,
    });

type ProvidersProps = {
  children: ReactNode;
};

export function Providers({ children }: ProvidersProps) {
  const [queryClient] = useState(() => new QueryClient());

  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider>{children}</RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
