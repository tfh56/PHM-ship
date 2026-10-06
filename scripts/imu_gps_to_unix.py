#!/usr/bin/env python3
"""
imu_gps_to_unix.py
------------------
把 IMU 文件中的 GPS 时间（HHMMSS.SS 格式，UTC）转成 Unix 时间戳，
并保留原始字段。输入文件示例：
    $GTIMU,2397,144353.9600,-0.0170,...
    $GPFPD,2397,144353.9800,20.503,0.891,-1.294,34.75627488,119.45087031,...

输出：每行一个 JSON，包含 unix_ts 字段。
"""
import sys, os, json, datetime

def gps_to_unix(date_str: str, gps_time_str: str) -> float:
    """
    date_str: 形如 '20251216'（YYYYMMDD），由文件名推断
    gps_time_str: 形如 '144353.9600'（HHMMSS.SS，UTC）
    """
    hh = int(gps_time_str[0:2])
    mm = int(gps_time_str[2:4])
    ss = float(gps_time_str[4:])
    yyyy = int(date_str[0:4])
    mo   = int(date_str[4:6])
    dd   = int(date_str[6:8])
    dt = datetime.datetime(yyyy, mo, dd, hh, mm, int(ss),
                           int((ss - int(ss)) * 1_000_000),
                           tzinfo=datetime.timezone.utc)
    return dt.timestamp()

def main():
    if len(sys.argv) < 3:
        print("用法: imu_gps_to_unix.py <input.txt> <output.txt>", file=sys.stderr)
        sys.exit(1)
    src, dst = sys.argv[1], sys.argv[2]
    # 从文件名提取日期：imu_20251216-000534.txt -> 20251216
    base = os.path.basename(src)
    date_str = ''
    for tok in base.replace('_', '-').split('-'):
        if len(tok) == 8 and tok.isdigit():
            date_str = tok; break
    if not date_str:
        # fallback：用今天
        date_str = datetime.datetime.utcnow().strftime('%Y%m%d')
        print(f"[warn] 无法从文件名解析日期，使用今天: {date_str}", file=sys.stderr)

    with open(src, 'r', errors='ignore') as f, open(dst, 'w') as out:
        for line in f:
            line = line.strip()
            if not line or not line.startswith('$'):
                continue
            parts = line.split(',')
            sentence = parts[0]  # $GTIMU / $GPFPD
            # parts[2] 是 GPS 时间
            if len(parts) < 3:
                continue
            gps_time = parts[2]
            try:
                unix_ts = gps_to_unix(date_str, gps_time)
            except Exception as e:
                print(f"[warn] 时间转换失败 {gps_time}: {e}", file=sys.stderr)
                continue
            record = {
                'sentence': sentence,
                'raw': line,
                'gps_week_sec': parts[1] if len(parts) > 1 else None,
                'gps_time': gps_time,
                'unix_ts': unix_ts,
                '@timestamp': datetime.datetime.fromtimestamp(unix_ts, datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
                'fields': parts[3:] if len(parts) > 3 else []
            }
            # GPFPD 额外解析经纬度
            if sentence == '$GPFPD' and len(parts) >= 9:
                try:
                    record['lat'] = float(parts[6])
                    record['lon'] = float(parts[7])
                    record['heading'] = float(parts[3]) if parts[3] else None
                    record['pitch']   = float(parts[4]) if parts[4] else None
                    record['roll']    = float(parts[5]) if parts[5] else None
                except ValueError:
                    pass
            # GTIMU 额外解析加速度/角速度
            if sentence == '$GTIMU' and len(parts) >= 10:
                try:
                    record['accel_x'] = float(parts[3])
                    record['accel_y'] = float(parts[4])
                    record['accel_z'] = float(parts[5])
                    record['gyro_x']  = float(parts[6])
                    record['gyro_y']  = float(parts[7])
                    record['gyro_z']  = float(parts[8])
                    record['temp']    = float(parts[9].split('*')[0])
                except ValueError:
                    pass
            out.write(json.dumps(record, ensure_ascii=False) + '\n')
    print(f"[ok] {src} -> {dst}  (date={date_str})")

if __name__ == '__main__':
    main()
