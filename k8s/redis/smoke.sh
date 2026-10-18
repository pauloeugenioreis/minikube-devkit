redis-cli -a "$REDIS_PASSWORD" --no-auth-warning SET devkit:smoke ok | grep -q OK && redis-cli -a "$REDIS_PASSWORD" --no-auth-warning GET devkit:smoke | grep -qx ok
