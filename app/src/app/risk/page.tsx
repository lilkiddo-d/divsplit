export const metadata = { title: "Risk disclosure · Divsplit" };

export default function RiskPage() {
  return (
    <div className="prose">
      <h1>Risk disclosure</h1>
      <p className="lead">
        Divsplit is experimental, unaudited software. You can lose some or all of the value you put into it. Read
        this page in full before splitting, trading or providing liquidity.
      </p>

      <h2>What you hold</h2>
      <ul>
        <li>
          <strong>Price token (P)</strong>: after expiry it redeems for the stock-token amount set aside for it. Before
          expiry its price is the stock price minus the market&apos;s estimate of dividends until expiry.
        </li>
        <li>
          <strong>Dividend token (D)</strong>: receives every dividend the protocol captures until the dividend cutoff
          (expiry plus a short trailing window). After that it is worth nothing except dividends already accrued. Its
          price can fall to zero well before expiry if dividends are cut.
        </li>
        <li>P and D are product tokens of this protocol. They are not shares, not the stock token, and give no
          rights against any company or token issuer.</li>
      </ul>

      <h2>Underlying stock-token risk</h2>
      <ul>
        <li>
          The stock tokens are issued by a third party, not by Divsplit. The issuer can pause transfers, block
          addresses (including the protocol&apos;s contracts), upgrade the token contract, or change how dividends
          and corporate actions are handled. Any of these can freeze or impair P and D.
        </li>
        <li>
          Dividends are detected from on-chain signals (a share multiplier). Splits and reverse splits are treated as
          value-neutral; ambiguous changes halt the market until governance resolves them through a 48-hour
          timelock. During that time split, merge and redeem are unavailable.
        </li>
        <li>Stock tokens may be restricted in your jurisdiction. You are responsible for complying with local law.</li>
      </ul>

      <h2>Market and liquidity risk</h2>
      <ul>
        <li>The built-in pools can be thin. Large trades move prices; slippage limits protect you only up to the
          tolerance you set.</li>
        <li>Pool pricing uses oracle prices. Stale or deviating oracle data halts trading. Oracle failures or
          manipulation could cause losses for traders and liquidity providers.</li>
        <li>Liquidity providers in the P pool carry stock-price risk; in the D pool they carry dividend risk. Pool
          prices converge towards P = one pair and D = 0 at expiry.</li>
        <li>Swaps stop at expiry. Removing liquidity is always possible.</li>
      </ul>

      <h2>Smart-contract and governance risk</h2>
      <ul>
        <li>The contracts have been tested and statically analysed but not independently audited.</li>
        <li>A guardian can pause markets. Configuration changes go through a 48-hour timelock controlled by the
          protocol team. Claims and liquidity withdrawals remain available while paused.</li>
        <li>An optional compliance allowlist can restrict who may split, merge, trade or add liquidity. Redeeming,
          claiming and removing liquidity are never restricted.</li>
      </ul>

      <h2>No advice</h2>
      <p>
        Nothing on this site is investment, legal or tax advice. Implied yields are mathematical transformations of
        market prices, not forecasts. Past dividends do not predict future dividends.
      </p>
    </div>
  );
}
