using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Web.Script.Serialization;

namespace PlexLibraryHelper
{
    // Small helpers over JavaScriptSerializer results (objects are dictionaries, arrays are object[]),
    // so the rest of the app can say j.S("title") or j.O("compress").B("enabled") without casting.
    public static class Json
    {
        static readonly JavaScriptSerializer Ser = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 200 };

        public static Dictionary<string, object> Parse(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return null;
            try { return Ser.DeserializeObject(text.Trim().TrimStart('﻿')) as Dictionary<string, object>; } catch { return null; }
        }
        public static object ParseAny(string text) { try { return Ser.DeserializeObject(text.Trim().TrimStart('﻿')); } catch { return null; } }
        public static string Write(object o) => Ser.Serialize(o);

        public static object Get(this Dictionary<string, object> d, string key)
        {
            if (d == null) return null;
            if (d.TryGetValue(key, out var v)) return v;
            // PowerShell's ConvertTo-Json keeps the case it was given; be forgiving
            foreach (var kv in d) if (string.Equals(kv.Key, key, StringComparison.OrdinalIgnoreCase)) return kv.Value;
            return null;
        }
        public static Dictionary<string, object> O(this Dictionary<string, object> d, string key) => d.Get(key) as Dictionary<string, object>;
        public static string S(this Dictionary<string, object> d, string key) { var v = d.Get(key); return v == null ? null : Convert.ToString(v, CultureInfo.InvariantCulture); }
        public static bool B(this Dictionary<string, object> d, string key)
        {
            var v = d.Get(key);
            if (v is bool b) return b;
            if (v is string s) return s.Equals("true", StringComparison.OrdinalIgnoreCase);
            return v != null && !(v is Dictionary<string, object>) && D(d, key) != 0;
        }
        public static double D(this Dictionary<string, object> d, string key, double dflt = 0)
        {
            var v = d.Get(key);
            if (v == null) return dflt;
            try { return Convert.ToDouble(v, CultureInfo.InvariantCulture); } catch { return dflt; }
        }
        public static bool Has(this Dictionary<string, object> d, string key) => d.Get(key) != null;
        public static List<object> A(this Dictionary<string, object> d, string key)
        {
            var v = d.Get(key);
            if (v is object[] arr) return arr.ToList();
            if (v is ArrayList al) return al.Cast<object>().ToList();
            if (v == null) return new List<object>();
            return new List<object> { v };          // PowerShell turns one-item arrays into the item
        }
        public static List<Dictionary<string, object>> AO(this Dictionary<string, object> d, string key) => d.A(key).OfType<Dictionary<string, object>>().ToList();
        public static List<string> AS(this Dictionary<string, object> d, string key) => d.A(key).Where(x => x != null).Select(x => Convert.ToString(x, CultureInfo.InvariantCulture)).ToList();
    }
}
