import Link from "next/link";

const quickLinks = [
  { href: "/score", label: "Score Explorer" },
  { href: "/borrow", label: "Borrow Wizard" },
  { href: "/lend", label: "Lender Hub" },
];

export default function Footer() {
  return (
    <footer className="border-t-2 border-neutral-900 bg-white">
      <div className="mx-auto flex w-full max-w-6xl flex-col gap-6 px-6 py-8 md:flex-row md:items-center md:justify-between">
        <div>
          <p className="inline-block rounded-full border-2 border-neutral-900 bg-[#d4ff00] px-4 py-1 text-xs font-extrabold uppercase tracking-widest text-neutral-900 shadow-[2px_2px_0px_#000]">
            Built for Encode Club Mini DeFi
          </p>
          <p className="mt-3 text-sm font-medium text-neutral-600">
            AI scoring + ZK proof lending protocol on Base Sepolia.
          </p>
        </div>

        <nav aria-label="Footer quick links">
          <ul className="flex flex-wrap items-center gap-2">
            {quickLinks.map((link) => (
              <li key={link.href}>
                <Link
                  href={link.href}
                  className="no-underline inline-block rounded-full border-2 border-neutral-900 bg-[#f4f4f0] px-4 py-1 text-xs font-bold uppercase tracking-widest text-neutral-900 shadow-[2px_2px_0px_#000] transition-all hover:-translate-y-[1px] hover:bg-[#d4ff00]"
                >
                  {link.label}
                </Link>
              </li>
            ))}
          </ul>
        </nav>
      </div>
    </footer>
  );
}
