using System;
using System.Collections.Generic;
using System.Text;
using System.Windows;
using System.Windows.Media;

namespace PlexLibraryHelper
{
    // A small QR code generator (byte mode, error correction M, versions 1-10: up to 213 bytes), following the
    // QR Code specification the same way Project Nayuki's reference generator does. Used to put the ntfy topic
    // and the dashboard link on screen for the phone to scan.
    public sealed class QrCode
    {
        public readonly int Size;
        readonly bool[,] _mod, _fn;
        readonly int _ver;

        static readonly int[] EccPerBlockM = { -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26 };
        static readonly int[] BlocksM = { -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5 };

        public static QrCode Encode(string text)
        {
            var data = Encoding.UTF8.GetBytes(text);
            for (int ver = 1; ver <= 10; ver++)
            {
                int cap = DataCodewords(ver) * 8;
                int need = 4 + (ver <= 9 ? 8 : 16) + data.Length * 8;
                if (need <= cap) return new QrCode(ver, data);
            }
            throw new ArgumentException("Too long for a QR code here");
        }

        QrCode(int ver, byte[] data)
        {
            _ver = ver; Size = ver * 4 + 17;
            _mod = new bool[Size, Size]; _fn = new bool[Size, Size];

            // data bits: mode 0100 (bytes), length, bytes, terminator, pad to a byte, pad bytes
            var bits = new List<bool>();
            void Add(int val, int len) { for (int i = len - 1; i >= 0; i--) bits.Add(((val >> i) & 1) != 0); }
            Add(4, 4); Add(data.Length, ver <= 9 ? 8 : 16);
            foreach (var b in data) Add(b, 8);
            int capBits = DataCodewords(ver) * 8;
            Add(0, Math.Min(4, capBits - bits.Count));
            Add(0, (8 - bits.Count % 8) % 8);
            for (int pad = 0xEC; bits.Count < capBits; pad ^= 0xEC ^ 0x11) Add(pad, 8);
            var words = new byte[bits.Count / 8];
            for (int i = 0; i < bits.Count; i++) if (bits[i]) words[i >> 3] |= (byte)(1 << (7 - (i & 7)));

            DrawFunctionPatterns();
            DrawCodewords(AddEccAndInterleave(words));
            // choose the mask with the lowest penalty
            int best = 0; long bestPenalty = long.MaxValue;
            for (int m = 0; m < 8; m++)
            {
                ApplyMask(m); DrawFormatBits(m);
                long p = Penalty();
                if (p < bestPenalty) { best = m; bestPenalty = p; }
                ApplyMask(m);
            }
            ApplyMask(best); DrawFormatBits(best);
        }

        public bool this[int x, int y] => x >= 0 && y >= 0 && x < Size && y < Size && _mod[y, x];

        static int RawModules(int ver)
        {
            int r = (16 * ver + 128) * ver + 64;
            if (ver >= 2) { int n = ver / 7 + 2; r -= (25 * n - 10) * n - 55; if (ver >= 7) r -= 36; }
            return r;
        }
        static int DataCodewords(int ver) => RawModules(ver) / 8 - EccPerBlockM[ver] * BlocksM[ver];

        byte[] AddEccAndInterleave(byte[] data)
        {
            int numBlocks = BlocksM[_ver], eccLen = EccPerBlockM[_ver], raw = RawModules(_ver) / 8;
            int numShort = numBlocks - raw % numBlocks, shortLen = raw / numBlocks;
            var div = RsDivisor(eccLen);
            var blocks = new List<byte[]>();
            for (int i = 0, k = 0; i < numBlocks; i++)
            {
                int datLen = shortLen - eccLen + (i < numShort ? 0 : 1);
                var dat = new byte[datLen]; Array.Copy(data, k, dat, 0, datLen); k += datLen;
                var ecc = RsRemainder(dat, div);
                var block = new byte[shortLen + 1];
                Array.Copy(dat, 0, block, 0, datLen);
                Array.Copy(ecc, 0, block, block.Length - eccLen, eccLen);   // short blocks keep a gap before the ecc
                blocks.Add(block);
            }
            var result = new List<byte>();
            for (int i = 0; i < blocks[0].Length; i++)
                for (int j = 0; j < blocks.Count; j++)
                    if (i != shortLen - eccLen || j >= numShort) result.Add(blocks[j][i]);
            return result.ToArray();
        }

        static byte[] RsDivisor(int degree)
        {
            var r = new byte[degree]; r[degree - 1] = 1;
            int root = 1;
            for (int i = 0; i < degree; i++)
            {
                for (int j = 0; j < r.Length; j++) { r[j] = Mul(r[j], root); if (j + 1 < r.Length) r[j] ^= r[j + 1]; }
                root = Mul(root, 0x02);
            }
            return r;
        }
        static byte[] RsRemainder(byte[] data, byte[] div)
        {
            var r = new byte[div.Length];
            foreach (var b in data)
            {
                int factor = b ^ r[0];
                Array.Copy(r, 1, r, 0, r.Length - 1); r[r.Length - 1] = 0;
                for (int i = 0; i < r.Length; i++) r[i] ^= Mul(div[i], factor);
            }
            return r;
        }
        static byte Mul(int x, int y)
        {
            int z = 0;
            for (int i = 7; i >= 0; i--) { z = (z << 1) ^ ((z >> 7) * 0x11D); z ^= ((y >> i) & 1) * x; }
            return (byte)z;
        }

        void Set(int x, int y, bool dark) { _mod[y, x] = dark; _fn[y, x] = true; }

        void DrawFunctionPatterns()
        {
            for (int i = 0; i < Size; i++) { Set(6, i, i % 2 == 0); Set(i, 6, i % 2 == 0); }
            Finder(3, 3); Finder(Size - 4, 3); Finder(3, Size - 4);
            var pos = AlignmentPositions(); int n = pos.Length;
            for (int i = 0; i < n; i++)
                for (int j = 0; j < n; j++)
                    if (!(i == 0 && j == 0 || i == 0 && j == n - 1 || i == n - 1 && j == 0))
                        for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) Set(pos[i] + dx, pos[j] + dy, Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1);
            DrawFormatBits(0);
            if (_ver >= 7)
            {
                int rem = _ver;
                for (int i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
                int bits = _ver << 12 | rem;
                for (int i = 0; i < 18; i++) { bool bit = ((bits >> i) & 1) != 0; int a = Size - 11 + i % 3, b = i / 3; Set(a, b, bit); Set(b, a, bit); }
            }
        }

        void Finder(int x, int y)
        {
            for (int dy = -4; dy <= 4; dy++)
                for (int dx = -4; dx <= 4; dx++)
                {
                    int d = Math.Max(Math.Abs(dx), Math.Abs(dy)), xx = x + dx, yy = y + dy;
                    if (xx >= 0 && xx < Size && yy >= 0 && yy < Size) Set(xx, yy, d != 2 && d != 4);
                }
        }

        int[] AlignmentPositions()
        {
            if (_ver == 1) return new int[0];
            int n = _ver / 7 + 2;
            int step = (_ver * 8 + n * 3 + 5) / (n * 4 - 4) * 2;
            var r = new int[n]; r[0] = 6;
            for (int i = n - 1, p = Size - 7; i >= 1; i--, p -= step) r[i] = p;
            return r;
        }

        void DrawFormatBits(int mask)
        {
            int data = 0 << 3 | mask;                       // error correction M = 00
            int rem = data;
            for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
            int bits = (data << 10 | rem) ^ 0x5412;
            bool B(int i) => ((bits >> i) & 1) != 0;
            for (int i = 0; i <= 5; i++) Set(8, i, B(i));
            Set(8, 7, B(6)); Set(8, 8, B(7)); Set(7, 8, B(8));
            for (int i = 9; i < 15; i++) Set(14 - i, 8, B(i));
            for (int i = 0; i < 8; i++) Set(Size - 1 - i, 8, B(i));
            for (int i = 8; i < 15; i++) Set(8, Size - 15 + i, B(i));
            Set(8, Size - 8, true);
        }

        void DrawCodewords(byte[] data)
        {
            int i = 0;
            for (int right = Size - 1; right >= 1; right -= 2)
            {
                if (right == 6) right = 5;
                for (int vert = 0; vert < Size; vert++)
                    for (int j = 0; j < 2; j++)
                    {
                        int x = right - j;
                        bool upward = ((right + 1) & 2) == 0;
                        int y = upward ? Size - 1 - vert : vert;
                        if (!_fn[y, x] && i < data.Length * 8) { _mod[y, x] = ((data[i >> 3] >> (7 - (i & 7))) & 1) != 0; i++; }
                    }
            }
        }

        void ApplyMask(int m)
        {
            for (int y = 0; y < Size; y++)
                for (int x = 0; x < Size; x++)
                {
                    bool inv;
                    switch (m)
                    {
                        case 0: inv = (x + y) % 2 == 0; break;
                        case 1: inv = y % 2 == 0; break;
                        case 2: inv = x % 3 == 0; break;
                        case 3: inv = (x + y) % 3 == 0; break;
                        case 4: inv = (x / 3 + y / 2) % 2 == 0; break;
                        case 5: inv = x * y % 2 + x * y % 3 == 0; break;
                        case 6: inv = (x * y % 2 + x * y % 3) % 2 == 0; break;
                        default: inv = ((x + y) % 2 + x * y % 3) % 2 == 0; break;
                    }
                    if (inv && !_fn[y, x]) _mod[y, x] = !_mod[y, x];
                }
        }

        // A simplified version of the spec's penalty (long runs, 2x2 blocks, dark/light balance): enough to
        // avoid masks that are hard to scan
        long Penalty()
        {
            long p = 0; int dark = 0;
            for (int a = 0; a < Size; a++)
            {
                int runR = 1, runC = 1;
                for (int b = 1; b < Size; b++)
                {
                    if (_mod[a, b] == _mod[a, b - 1]) { runR++; if (runR == 5) p += 3; else if (runR > 5) p++; } else runR = 1;
                    if (_mod[b, a] == _mod[b - 1, a]) { runC++; if (runC == 5) p += 3; else if (runC > 5) p++; } else runC = 1;
                }
            }
            for (int y = 0; y < Size; y++)
                for (int x = 0; x < Size; x++)
                {
                    if (_mod[y, x]) dark++;
                    if (x > 0 && y > 0 && _mod[y, x] == _mod[y, x - 1] && _mod[y, x] == _mod[y - 1, x] && _mod[y, x] == _mod[y - 1, x - 1]) p += 3;
                }
            int total = Size * Size;
            p += (Math.Abs(dark * 20 - total * 10) + total - 1) / total * 10;
            return p;
        }

        // Black on white with a 4-module quiet zone, as a crisp vector image
        public DrawingImage ToImage()
        {
            var g = new GeometryGroup();
            for (int y = 0; y < Size; y++)
                for (int x = 0; x < Size; x++)
                    if (_mod[y, x]) g.Children.Add(new RectangleGeometry(new Rect(x + 4, y + 4, 1.02, 1.02)));
            var dg = new DrawingGroup();
            dg.Children.Add(new GeometryDrawing(Brushes.White, null, new RectangleGeometry(new Rect(0, 0, Size + 8, Size + 8))));
            dg.Children.Add(new GeometryDrawing(Brushes.Black, null, g));
            dg.Freeze();
            var img = new DrawingImage(dg); img.Freeze();
            return img;
        }
    }
}
