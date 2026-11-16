using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Minutes.Core;

public sealed class SwiftDateConverter:JsonConverter<DateTimeOffset>
{
    public override DateTimeOffset Read(ref Utf8JsonReader reader,Type type,JsonSerializerOptions options)
    {
        var text=reader.GetString();
        return DateTimeOffset.TryParse(text,CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind,out var date)?date:throw new JsonException("Invalid ISO-8601 date");
    }
    public override void Write(Utf8JsonWriter writer,DateTimeOffset value,JsonSerializerOptions options)=>writer.WriteStringValue(value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'",CultureInfo.InvariantCulture));
}
