# Shared synthetic chat-file fixtures

Exact copy of the JavaScript SDK's `test/fixtures/documents` binary fixtures and
manifest. Expected invoice: **7421**, vendor **Example Books**, total **USD 123.45**.
All data is synthetic. `invoice-scan.pdf` contains only the raster invoice.

The widgets test proves negotiated file selection preserves original bytes and
upload references. The client test uploads the original bytes through its HTTP
encoder, prepares a real turn submission and checks serialized/reopened saved
attachment events against `manifest.json`. JS server tests consume the same
manifest through canonical history preparation and captured provider input.

This cross-language fixture check is not an installed mobile application test or
proof of live provider extraction. Regenerate using the JS fixture generator and
copy both binary files and manifest together; never hand-edit their byte sizes.
