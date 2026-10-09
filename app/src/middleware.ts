import { NextResponse, type NextRequest } from "next/server";

/**
 * Optional geoblock. Set NEXT_PUBLIC_GEOBLOCK_COUNTRIES="US,CA,GB,CH" (ISO-3166 alpha-2) to deny those countries.
 * Uses the x-vercel-ip-country header set by Vercel's edge; when the header is absent (local dev) nothing is blocked.
 * The risk page stays reachable everywhere.
 */
const BLOCKED = (process.env.NEXT_PUBLIC_GEOBLOCK_COUNTRIES ?? "")
  .split(",")
  .map((c) => c.trim().toUpperCase())
  .filter(Boolean);

export function middleware(req: NextRequest) {
  if (BLOCKED.length === 0) return NextResponse.next();
  const country = req.headers.get("x-vercel-ip-country")?.toUpperCase();
  if (country && BLOCKED.includes(country)) {
    const url = req.nextUrl.clone();
    url.pathname = "/blocked";
    return NextResponse.rewrite(url);
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/|favicon|risk|blocked|api/corporate-actions).*)"],
};
