class Ahoy::Store < Ahoy::DatabaseStore
end

Ahoy.api = false
Ahoy.geocode = false
Ahoy.server_side_visits = :when_needed
Ahoy.cookies = :none
