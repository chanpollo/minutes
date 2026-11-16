using System.Net;
using System.Net.Http.Headers;

namespace Minutes.Core;

public static class ResumableDownload
{
    public static async Task FetchAsync(HttpClient http, string url, string part, IProgress<long>? progress = null, CancellationToken cancel = default)
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var offset = File.Exists(part) ? new FileInfo(part).Length : 0;
            using var request = new HttpRequestMessage(HttpMethod.Get, url); if (offset > 0) request.Headers.Range = new RangeHeaderValue(offset, null);
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel);
            if (response.StatusCode == HttpStatusCode.RequestedRangeNotSatisfiable && offset > 0) { File.Delete(part); continue; }
            response.EnsureSuccessStatusCode();
            var append = response.StatusCode == HttpStatusCode.PartialContent;
            if (append && response.Content.Headers.ContentRange?.From != offset) throw new IOException("The download server returned an unexpected byte range");
            if (!append) offset = 0;
            await using var input = await response.Content.ReadAsStreamAsync(cancel);
            await using var output = new FileStream(part, append ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1024 * 1024, true);
            var buffer = new byte[1024 * 1024]; long done = offset; int count;
            while ((count = await input.ReadAsync(buffer, cancel)) > 0) { await output.WriteAsync(buffer.AsMemory(0, count), cancel); done += count; progress?.Report(done); }
            return;
        }
        throw new IOException("The download could not resume");
    }
}
