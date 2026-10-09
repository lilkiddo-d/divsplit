"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useAccount, useConnect } from "wagmi";
import { DEV_IMPERSONATE, TOKEN_FEATURES } from "@/lib/config";

export function Nav() {
  const path = usePathname();
  const { isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const devConnector = connectors.find((c) => c.id === "mock");
  const links = [
    { href: "/", label: "Markets" },
    { href: "/portfolio", label: "Portfolio" },
    ...(TOKEN_FEATURES ? [{ href: "/govern", label: "Stake & Vote" }] : []),
    { href: "/risk", label: "Risk disclosure" },
  ];
  return (
    <header className="top">
      <div className="container">
        <Link href="/" className="brand">
          Div<span>split</span>
        </Link>
        <nav className="main">
          {links.map((l) => (
            <Link key={l.href} href={l.href} className={path === l.href ? "active" : ""}>
              {l.label}
            </Link>
          ))}
        </nav>
        {DEV_IMPERSONATE && devConnector && !isConnected && (
          <button className="btn secondary" onClick={() => connect({ connector: devConnector })} title="Local fork only">
            Use fork test account
          </button>
        )}
        <ConnectButton chainStatus="icon" showBalance={false} accountStatus="address" />
      </div>
    </header>
  );
}
