local typedefs = require "kong.db.schema.typedefs"

return {
    name = "token-introspection",
    fields = {
        {
            config = {
                type = "record",
                fields = {
                    {
                        allow_anonymous = { type = "boolean", default = false }
                    },
                    {
                        cache_ttl = { type = "number", default = 60 }
                    },
                    {
                        endpoint = { type = "string" }
                    }
                },
                entity_checks = {

                }
            }
        }
    },
}