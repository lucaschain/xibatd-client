// Same framebuffer sampling convention as the standard outfit outline.
uniform sampler2D u_Tex0;
uniform float u_Time;
varying vec2 v_TexCoord;

void main()
{
    vec4 color = texture2D(u_Tex0, v_TexCoord);
    float pulse = 0.86 + 0.14 * sin(u_Time * 2.0);
    vec3 gold = vec3(1.0, 0.72, 0.20);
    if (color.a > 0.5) {
        // Preserve the monster's silhouette and original palette.
        color.rgb = mix(color.rgb, gold, 0.10 * pulse);
        gl_FragColor = color;
    } else {
        vec2 stepSize = vec2(1.0 / 64.0);
        float edge = max(max(texture2D(u_Tex0, v_TexCoord + vec2(stepSize.x, 0.0)).a,
                             texture2D(u_Tex0, v_TexCoord - vec2(stepSize.x, 0.0)).a),
                         max(texture2D(u_Tex0, v_TexCoord + vec2(0.0, stepSize.y)).a,
                             texture2D(u_Tex0, v_TexCoord - vec2(0.0, stepSize.y)).a));
        gl_FragColor = edge > 0.5 ? vec4(gold * pulse, 0.85 * pulse) : color;
    }
}
