"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { RainbowKitProvider, connectorsForWallets, darkTheme, lightTheme } from "@rainbow-me/rainbowkit";
import { injectedWallet, metaMaskWallet, rabbyWallet, walletConnectWallet } from "@rainbow-me/rainbowkit/wallets";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";
import { WagmiProvider, createConfig, http } from "wagmi";
import { mock } from "@wagmi/core";
import { appChain, RPC_URL, DEV_IMPERSONATE } from "@/lib/config";

const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID || "";

const connectors = connectorsForWallets(
  [
    {
      groupName: "Wallets",
      wallets: projectId ? [injectedWallet, metaMaskWallet, rabbyWallet, walletConnectWallet] : [injectedWallet],
    },
  ],
  { appName: "Divsplit", projectId: projectId || "divsplit-local" },
);

// Local-fork only: an impersonated account. anvil --auto-impersonate signs eth_sendTransaction for it, so no key
// exists anywhere. Never enabled unless NEXT_PUBLIC_DEV_IMPERSONATE is set AND the RPC is localhost.
const devConnectors = DEV_IMPERSONATE ? [mock({ accounts: [DEV_IMPERSONATE], features: { reconnect: true } })] : [];

const wagmiConfig = createConfig({
  chains: [appChain],
  connectors: [...connectors, ...devConnectors],
  transports: { [appChain.id]: http(RPC_URL, { batch: true }) },
  ssr: true,
});

export function Providers({ children }: { children: ReactNode }) {
  const [client] = useState(() => new QueryClient({ defaultOptions: { queries: { refetchInterval: 15_000, staleTime: 10_000 } } }));
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={client}>
        <RainbowKitProvider theme={{ lightMode: lightTheme({ accentColor: "#0f766e" }), darkMode: darkTheme({ accentColor: "#2dd4bf" }) }}>
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
