import { Plugin } from "@opencode/plugin"

export default Plugin.define({
  id: "opencode-home-notify",
  setup(ctx) {
    const controller = new AbortController()

    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({
          types: ["session.idle"],
          signal: controller.signal,
        })) {
          if (event.type !== "session.idle") continue

          const child = Bun.spawn(
            [`${process.env.HOME}/.local/bin/client-watchdog.sh`, "--notify-done"],
            {
              stdout: "ignore",
              stderr: "pipe",
            },
          )

          const exitCode = await child.exited
          if (exitCode !== 0) {
            const stderr = await new Response(child.stderr).text()
            console.error(`[opencode-home-notify] Notification failed: ${stderr.trim()}`)
          }
        }
      } catch (error) {
        if (!controller.signal.aborted) {
          console.error("[opencode-home-notify] Event subscription failed:", error)
        }
      }
    })()

    return () => controller.abort()
  },
})
