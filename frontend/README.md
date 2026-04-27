# CreditLayer Frontend

Next.js 14 App Router frontend for CreditLayer.

## Implemented in this step

- App routes:
  - `app/page.tsx`
  - `app/borrow/page.tsx`
  - `app/lend/page.tsx`
  - `app/score/page.tsx`
- Components:
  - `components/ScoreCard.tsx`
  - `components/LoanPanel.tsx`
  - `components/ZKProofGenerator.tsx`
  - `components/HealthBar.tsx`
- Hooks:
  - `hooks/useCreditScore.ts`
  - `hooks/useLoanPool.ts`
- Lib:
  - `lib/contracts.ts`
  - `lib/hypersync.ts`

## Environment variables

Create `.env.local`:

- `NEXT_PUBLIC_BASE_RPC_URL`
- `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`
- `NEXT_PUBLIC_CREDIT_SCORE_NFT_ADDRESS`
- `NEXT_PUBLIC_LENDING_POOL_ADDRESS`
- `NEXT_PUBLIC_CREDIT_ORACLE_ADDRESS`
- `NEXT_PUBLIC_USDC_ADDRESS`
- `NEXT_PUBLIC_AGENT_URL`

## Run

```bash
npm install
npm run dev
```

Then open `http://localhost:3000`.
