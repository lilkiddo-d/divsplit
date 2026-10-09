/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // allow importing the repo-level /config/chains.ts
  experimental: { externalDir: true },
  webpack: (config) => {
    // optional peer deps pulled in by wallet SDKs that are not needed in the browser bundle
    config.externals.push("pino-pretty", "lokijs", "encoding");
    config.resolve.fallback = { ...config.resolve.fallback, "@react-native-async-storage/async-storage": false };
    // optional payment-protocol deps of a wallet SDK bundled by @wagmi/connectors; never used by Divsplit
    config.resolve.alias = {
      ...config.resolve.alias,
      "@x402/evm": false,
      "@x402/evm/exact/client": false,
      "@x402/evm/upto/client": false,
      "@x402/core/client": false,
      "@x402/svm/exact/client": false,
    };
    return config;
  },
};

export default nextConfig;
