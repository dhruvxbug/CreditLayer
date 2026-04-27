"use client";

import Link from "next/link";
import { ConnectButton } from "@rainbow-me/rainbowkit";

const navLinks = [
  { href: "/", label: "Dashboard" },
  { href: "/score", label: "Score" },
  { href: "/borrow", label: "Borrow" },
  { href: "/lend", label: "Lend" },
  { href: "/docs", label: "Docs" },
];

export default function Navbar() {
  return (
    <header className="sticky top-0 z-40 border-b-2 border-neutral-900 bg-[#f4f4f0]/95 backdrop-blur supports-[backdrop-filter]:bg-[#f4f4f0]/80">
      <div className="mx-auto flex w-full max-w-6xl flex-wrap items-center justify-between gap-4 px-6 py-4">
        <Link
          href="/"
          className="no-underline rounded-full border-2 border-neutral-900 bg-white px-4 py-1 text-sm font-bold uppercase tracking-widest shadow-[3px_3px_0px_#000] hover:bg-[#d4ff00]"
        >
          CreditLayer
        </Link>

        <nav className="order-3 w-full sm:order-2 sm:w-auto">
          <ul className="flex flex-wrap items-center gap-2">
            {navLinks.map((link) => (
              <li key={link.href}>
                <Link
                  href={link.href}
                  className="no-underline inline-block rounded-full border-2 border-neutral-900 bg-white px-4 py-1 text-xs font-bold uppercase tracking-widest text-neutral-900 shadow-[2px_2px_0px_#000] transition-all hover:-translate-y-[1px] hover:bg-[#d4ff00]"
                >
                  {link.label}
                </Link>
              </li>
            ))}
          </ul>
        </nav>

        <div className="order-2 sm:order-3">
          <ConnectButton />
        </div>
      </div>
    </header>
  );
}
