# The entry point `juliac --trim=safe` compiles into the native `soleil` executable.
using Soleil

function (@main)(args::Vector{String})
    Soleil.run()
    return 0
end
