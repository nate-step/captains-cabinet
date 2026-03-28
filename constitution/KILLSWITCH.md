# KILL SWITCH

**Redis key:** `cabinet:killswitch`  
**Check frequency:** Every tool invocation (pre-tool-use hook)  
**Activation:** Captain sends `/killswitch` to @sensed_cos_bot  
**Deactivation:** Captain sends `/resume` to @sensed_cos_bot  

## What Happens on Activation

1. CoS sets Redis key `cabinet:killswitch` to `"active"`
2. All Officers' pre-tool-use hooks detect the key
3. All tool executions are blocked with message: "KILL SWITCH ACTIVE — all operations halted by Captain"
4. Officers send confirmation to Warroom: "[Officer] halted"
5. No further work occurs until the Captain sends `/resume`

## Manual Kill (Emergency)

If Telegram is unreachable, SSH into the server and run:

```bash
docker compose -f /opt/founders-cabinet/cabinet/docker-compose.yml exec redis redis-cli SET cabinet:killswitch active
```

To resume:

```bash
docker compose -f /opt/founders-cabinet/cabinet/docker-compose.yml exec redis redis-cli DEL cabinet:killswitch
```

## Nuclear Option

Stop all containers immediately:

```bash
cd /opt/founders-cabinet/cabinet && docker compose down
```
