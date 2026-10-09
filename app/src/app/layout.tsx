import type { Metadata } from "next";
import type { ReactNode } from "react";
import "./globals.css";
import { Providers } from "./providers";
import { Nav } from "@/components/Nav";

export const metadata: Metadata = {
  title: "Divsplit",
  description: "Split dividend-paying stock tokens into a Price token and a Dividend token.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Nav />
          <main>
            <div className="container">{children}</div>
          </main>
          <footer className="foot">
            <div className="container">
              Divsplit is experimental, unaudited software. Price and Dividend tokens are not offered to persons in
              restricted jurisdictions and carry substantial risk. Read the <a href="/risk">risk disclosure</a> before
              using the protocol. Divsplit is independent and not affiliated with any stock-token issuer.
            </div>
          </footer>
        </Providers>
      </body>
    </html>
  );
}
