import Foundation

// `Shop [path/to/contract.json]` (default: contract.json in the current directory) reads the contract, then the
// process environment. On a problem it prints every violation at once to standard error and exits 1, without
// printing a secret; otherwise it prints one line for its role and exits 0. A real web server or worker would start
// here.
let contractPath = CommandLine.arguments.dropFirst().first ?? "contract.json"
let config = await ShopConfig.loadOrExit(contract: contractPath)
print(config.summary)
