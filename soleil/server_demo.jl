using Servo
using Soleil

server = Soleil.run!(; host="127.0.0.1")
println("Soleil is serving at http://127.0.0.1:", Servo.port(server), ". Press Enter to stop it.")
try
    readline()
finally
    close(server)
end
