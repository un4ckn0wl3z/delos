# Demo library for screenshots

Makes a made-up library (fictional movies, series and albums with generated artwork), runs Delos on it with a fake TMDB, and takes the README screenshots.

```bash
go build -o /tmp/streammkv-demo .        # from the repo root
cd tools/demo
python3 gen.py                           # artwork + media in /tmp/demo/media (a few minutes)
./run.sh && python3 setup.py             # fresh server on :8097, libraries, users, roles, progress
sleep 95 && python3 shots.py             # screenshots in tools/demo/out
```
