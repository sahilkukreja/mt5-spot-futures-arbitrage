# Transaction Cost Model

Status: NOT STARTED

## Purpose
Compute the true net executable edge by subtracting all real costs from the raw spread.

## Cost components
Spot spread cost, Futures spread cost, Spot commission, Futures commission, Expected entry slippage,
Expected exit slippage, Financing, Swap, Carry, Rollover, Currency conversion, Latency uncertainty,
Execution-risk buffer.

## Deliverable
Net Executable Edge = Raw Spread − sum(cost components).
Trading should only be considered when Net Executable Edge > Required Safety Margin.
