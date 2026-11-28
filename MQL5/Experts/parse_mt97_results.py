import os
import sys
import re
import glob
import xml.etree.ElementTree as ET

def parse_xml_report(xml_path):
    tree = ET.parse(xml_path)
    root = tree.getroot()
    ns = {'ss': 'urn:schemas-microsoft-com:office:spreadsheet'}
    rows = root.findall('.//ss:Row', ns)
    if len(rows) < 2:
        return []
    headers = [c.find('ss:Data', ns).text if c.find('ss:Data', ns) is not None else '' for c in rows.findall('ss:Cell', ns)]
    records = []
    for r in rows[1:]:
        vals = []
        for c in r.findall('ss:Cell', ns):
            d = c.find('ss:Data', ns)
            vals.append(d.text if d is not None else '')
        if len(vals) >= len(headers):
            records.append(dict(zip(headers, vals)))
    return records

def parse_html_report(html_path):
    with open(html_path, 'r', encoding='utf-16', errors='ignore') as f:
        text = f.read()
    if '<html' not in text.lower():
        with open(html_path, 'r', encoding='utf-8', errors='ignore') as f:
            text = f.read()
    def find_metric(label):
        m = re.search(rf'{label}.*?<td[^>]*><b>([^<]+)</b>', text, re.S | re.I)
        return m.group(1).strip() if m else 'N/A'
    return {
        'Profit': find_metric('Total Net Profit'),
        'Profit Factor': find_metric('Profit Factor'),
        'Sharpe Ratio': find_metric('Sharpe Ratio'),
        'Equity DD %': find_metric('Equity Drawdown Relative'),
        'Trades': find_metric('Total Trades')
    }

def main():
    res_dir = sys.argv[1]
    symbol = sys.argv[2]
    mode = sys.argv[3]

    print(f"### {symbol} ({mode.upper()} Mode)\n")
    xml_files = sorted(glob.glob(os.path.join(res_dir, "*.xml")))
    if xml_files:
        for xf in xml_files:
            recs = parse_xml_report(xf)
            if not recs:
                continue
            tag = "Forward" if "forward" in os.path.basename(xf).lower() else "In-Sample / All"
            print(f"**{tag} Top Passes (`{os.path.basename(xf)}`):**\n")
            print("| Pass | Profit ($) | PF | Sharpe | Equity DD % | Trades | H1_SS | Kalman | KER | ZScore | TP_ATR | BE_ATR | Hedge_ATR |")
            print("| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |")
            for row in recs[:5]:
                print(f"| {row.get('Pass','-')} | {row.get('Profit','-')} | {row.get('Profit Factor','-')} | {row.get('Sharpe Ratio','-')} | {row.get('Equity DD %','-')}% | {row.get('Trades','-')} | {row.get('InpH1_SuperSmoothPeriod','-')} | {row.get('InpKalmanGain','-')} | {row.get('InpKER_MinChop','-')} | {row.get('InpVWAP_EntryZScore','-')} | {row.get('InpScalpTP_ATR_Mult','-')} | {row.get('InpBreakEven_ATR','-')} | {row.get('InpHedgeTrigger_ATR','-')} |")
            print("")
        return

    htm_files = sorted(glob.glob(os.path.join(res_dir, "*.htm*")))
    if htm_files:
        m = parse_html_report(htm_files)
        print("| Symbol | Net Profit | Profit Factor | Sharpe | Equity DD | Total Trades |")
        print("| :--- | :--- | :--- | :--- | :--- | :--- |")
        print(f"| **{symbol}** | {m['Profit']} | {m['Profit Factor']} | {m['Sharpe Ratio']} | {m['Equity DD %']} | {m['Trades']} |\n")
    else:
        print(f"_No report files generated for {symbol}. Check Tester logs in Artifacts._\n")

if __name__ == "__main__":
    main()
