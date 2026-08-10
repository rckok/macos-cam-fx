#include "ShaderTranspiler.h"

#include <glslang/Public/ShaderLang.h>
#include <glslang/Public/ResourceLimits.h>
#include <glslang/SPIRV/GlslangToSpv.h>

#include <spirv_cross/spirv_msl.hpp>

#include <cstdint>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

namespace {

char* copy_string(const std::string& s) {
    char* out = static_cast<char*>(std::malloc(s.size() + 1));
    std::memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

void append_json_string(std::ostringstream& os, const std::string& s) {
    os << '"';
    for (char c : s) {
        switch (c) {
            case '"': os << "\\\""; break;
            case '\\': os << "\\\\"; break;
            case '\n': os << "\\n"; break;
            case '\t': os << "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    os << buf;
                } else {
                    os << c;
                }
        }
    }
    os << '"';
}

std::string glsl_type_name(const spirv_cross::SPIRType& type) {
    using spirv_cross::SPIRType;
    std::string base;
    switch (type.basetype) {
        case SPIRType::Float: base = type.vecsize > 1 ? "vec" : "float"; break;
        case SPIRType::Int: base = type.vecsize > 1 ? "ivec" : "int"; break;
        case SPIRType::UInt: base = type.vecsize > 1 ? "uvec" : "uint"; break;
        case SPIRType::Boolean: base = type.vecsize > 1 ? "bvec" : "bool"; break;
        default: base = "unsupported"; break;
    }
    if (type.columns > 1) {
        return "mat" + std::to_string(type.columns);
    }
    if (type.vecsize > 1) {
        base += std::to_string(type.vecsize);
    }
    return base;
}

int64_t msl_index_or_minus_one(uint32_t index) {
    return index == UINT32_MAX ? -1 : static_cast<int64_t>(index);
}

} // namespace

extern "C" {

int st_initialize(void) {
    return glslang::InitializeProcess() ? 0 : 1;
}

void st_finalize(void) {
    glslang::FinalizeProcess();
}

int st_compile_fragment(const char* glsl_source,
                        char** out_msl,
                        char** out_reflection_json,
                        char** out_log) {
    if (out_msl) *out_msl = nullptr;
    if (out_reflection_json) *out_reflection_json = nullptr;
    if (out_log) *out_log = nullptr;

    // --- GLSL -> SPIR-V (glslang) ---
    glslang::TShader shader(EShLangFragment);
    shader.setStrings(&glsl_source, 1);
    shader.setEnvInput(glslang::EShSourceGlsl, EShLangFragment, glslang::EShClientVulkan, 100);
    shader.setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_1);
    shader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_3);
    shader.setAutoMapBindings(true);
    shader.setAutoMapLocations(true);

    const EShMessages messages = static_cast<EShMessages>(EShMsgSpvRules | EShMsgVulkanRules);

    if (!shader.parse(GetDefaultResources(), 450, ECoreProfile, false, false, messages)) {
        if (out_log) {
            std::string log = shader.getInfoLog();
            *out_log = copy_string(log);
        }
        return 1;
    }

    glslang::TProgram program;
    program.addShader(&shader);
    if (!program.link(messages) || !program.mapIO()) {
        if (out_log) {
            std::string log = program.getInfoLog();
            *out_log = copy_string(log);
        }
        return 1;
    }

    std::vector<uint32_t> spirv;
    glslang::SpvOptions spvOptions;
    spvOptions.disableOptimizer = true;
    spvOptions.validate = false;
    glslang::GlslangToSpv(*program.getIntermediate(EShLangFragment), spirv, &spvOptions);

    // --- SPIR-V -> MSL (SPIRV-Cross) ---
    try {
        spirv_cross::CompilerMSL msl(std::move(spirv));

        spirv_cross::CompilerMSL::Options mslOptions;
        mslOptions.platform = spirv_cross::CompilerMSL::Options::macOS;
        mslOptions.set_msl_version(2, 3);
        msl.set_msl_options(mslOptions);

        const std::string mslSource = msl.compile();

        // --- Reflection ---
        spirv_cross::ShaderResources resources = msl.get_shader_resources();

        std::ostringstream json;
        json << "{\"entryPoint\":\"main0\",\"textures\":[";

        bool first = true;
        for (const auto& res : resources.sampled_images) {
            if (!first) json << ',';
            first = false;

            const auto& type = msl.get_type(res.type_id);
            const char* dim = type.image.dim == spv::Dim3D ? "3d"
                            : type.image.dim == spv::Dim2D ? "2d"
                            : "other";
            json << "{\"name\":";
            append_json_string(json, res.name);
            json << ",\"binding\":" << msl.get_decoration(res.id, spv::DecorationBinding)
                 << ",\"mslTexture\":" << msl_index_or_minus_one(msl.get_automatic_msl_resource_binding(res.id))
                 << ",\"mslSampler\":" << msl_index_or_minus_one(msl.get_automatic_msl_resource_binding_secondary(res.id))
                 << ",\"dim\":\"" << dim << "\"}";
        }

        json << "],\"uniformBlocks\":[";
        first = true;
        for (const auto& res : resources.uniform_buffers) {
            if (!first) json << ',';
            first = false;

            const auto& blockType = msl.get_type(res.base_type_id);
            const size_t size = msl.get_declared_struct_size(blockType);

            json << "{\"name\":";
            append_json_string(json, res.name);
            json << ",\"binding\":" << msl.get_decoration(res.id, spv::DecorationBinding)
                 << ",\"mslBuffer\":" << msl_index_or_minus_one(msl.get_automatic_msl_resource_binding(res.id))
                 << ",\"size\":" << size
                 << ",\"members\":[";

            for (uint32_t i = 0; i < blockType.member_types.size(); ++i) {
                if (i > 0) json << ',';
                const auto& memberType = msl.get_type(blockType.member_types[i]);
                json << "{\"name\":";
                append_json_string(json, msl.get_member_name(res.base_type_id, i));
                json << ",\"type\":\"" << glsl_type_name(memberType) << "\""
                     << ",\"offset\":" << msl.type_struct_member_offset(blockType, i)
                     << "}";
            }
            json << "]}";
        }
        json << "]}";

        if (out_msl) *out_msl = copy_string(mslSource);
        if (out_reflection_json) *out_reflection_json = copy_string(json.str());
        return 0;
    } catch (const std::exception& e) {
        if (out_log) {
            *out_log = copy_string(std::string("ERROR: MSL conversion failed: ") + e.what());
        }
        return 2;
    }
}

void st_string_free(char* str) {
    std::free(str);
}

} // extern "C"
