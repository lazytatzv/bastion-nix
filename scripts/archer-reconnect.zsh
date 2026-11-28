archer() {
  while true; do
    command ssh \
      -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=3 \
      archer "$@"
    local status=$?

    if (( status == 0 )); then
      return 0
    fi

    printf 'ssh archer disconnected (status %d); reconnecting in 2s... (Ctrl-C to stop)\n' \
      "$status" >&2
    sleep 2
  done
}
