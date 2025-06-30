// specify rootsignature
#define computeRS "RootFlags(0), UAV(u0, visibility = SHADER_VISIBILITY_ALL)"

RWStructuredBuffer<uint> buffer : register(u0);

[RootSignature(computeRS)]
[numthreads(64, 1, 1)]
void main(uint3 DTid : SV_DispatchThreadID)
{
    buffer[DTid.x] *= 2; // Double each value
}