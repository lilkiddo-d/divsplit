export const metadata = { title: "Unavailable · Divsplit" };

export default function BlockedPage() {
  return (
    <div className="card prose">
      <h1>Not available in your region</h1>
      <p>
        This interface is not offered in your jurisdiction. The underlying contracts are public; if you already hold
        P or D tokens you can always redeem, claim and withdraw liquidity directly on-chain. See the{" "}
        <a href="/risk">risk disclosure</a>.
      </p>
    </div>
  );
}
