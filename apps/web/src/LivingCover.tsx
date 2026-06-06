import { useEffect, useRef } from "react";

/* WHITE LABEL v3 — living generative cover.
   Warm "Haze" motion by default (soft drifting fields); pass a hue (RGB 0..1)
   to tint it to an artist's world color. Pure WebGL, one context per mount.
   Falls back to nothing (transparent) if WebGL is unavailable — callers keep
   a CSS gradient behind it for that case. */

const VERT = "attribute vec2 p;void main(){gl_Position=vec4(p,0.0,1.0);}";
const FRAG = [
  "precision highp float;uniform vec2 u_res;uniform float u_time;uniform int u_tone;uniform vec3 u_hue;",
  "float hash(vec2 p){p=fract(p*vec2(123.34,456.21));p+=dot(p,p+45.32);return fract(p.x*p.y);}",
  "float noise(vec2 p){vec2 i=floor(p),f=fract(p);vec2 u=f*f*(3.0-2.0*f);float a=hash(i),b=hash(i+vec2(1.0,0.0)),c=hash(i+vec2(0.0,1.0)),d=hash(i+vec2(1.0,1.0));return mix(mix(a,b,u.x),mix(c,d,u.x),u.y);}",
  "float fbm(vec2 p){float v=0.0,a=0.5;for(int i=0;i<6;i++){v+=a*noise(p);p*=2.0;a*=0.5;}return v;}",
  "vec3 pal(float t,vec3 d){vec3 a=vec3(0.52,0.44,0.54),b=vec3(0.46,0.42,0.50),c=vec3(1.0,1.05,1.0);return a+b*cos(6.28318*(c*t+d));}",
  "vec3 hsv2rgb(vec3 c){vec3 r=clamp(abs(mod(c.x*6.0+vec3(0.0,4.0,2.0),6.0)-3.0)-1.0,0.0,1.0);return c.z*mix(vec3(1.0),r,c.y);}",
  "vec3 rgb2hsv(vec3 c){vec4 K=vec4(0.0,-0.3333333,0.6666667,-1.0);vec4 p=mix(vec4(c.bg,K.wz),vec4(c.gb,K.xy),step(c.b,c.g));vec4 q=mix(vec4(p.xyw,c.r),vec4(c.r,p.yzx),step(p.x,c.r));float d=q.x-min(q.w,q.y);float e=1.0e-10;return vec3(abs(q.z+(q.w-q.y)/(6.0*d+e)),d/(q.x+e),q.x);}",
  "void main(){vec2 uv=gl_FragCoord.xy/u_res.xy;float asp=u_res.x/u_res.y;vec2 p=vec2(uv.x*asp,uv.y)*1.7;",
  " float t2=u_time*0.052;vec2 sp=p*0.5;vec2 w=vec2(fbm(sp+vec2(0.0,t2)),fbm(sp+vec2(2.7,-0.9*t2)));float n2=fbm(sp+1.15*w+vec2(0.75*t2,0.18*t2));",
  " float ff=mix(uv.y*0.5+0.18,n2,0.76)+0.05*sin(u_time*0.22);vec3 col=pal(ff+u_time*0.013+0.05*w.x,vec3(0.58,0.42,0.30));",
  " float fc=clamp(ff,0.0,1.0);",
  " if(u_tone==3){vec3 h=rgb2hsv(u_hue);float val=0.24+0.72*fc;float sat=clamp(h.y*(1.2-0.5*fc),0.0,1.0);col=hsv2rgb(vec3(h.x+0.05*(fc-0.5),sat,val));}",
  " float lz=dot(col,vec3(0.333));col=mix(col,vec3(lz),0.15);col*=0.84;",
  " float vig=smoothstep(1.45,0.15,length(uv-0.5));col*=0.78+0.22*vig;gl_FragColor=vec4(col,1.0);}",
].join("\n");

function compile(gl: WebGLRenderingContext, type: number, src: string) {
  const s = gl.createShader(type)!;
  gl.shaderSource(s, src);
  gl.compileShader(s);
  return s;
}

/* Per-artist / per-room world color — a curated palette picked by a stable
   hash of the seed, so each room/artist gets a consistent cover hue. */
const COVER_HUES = ["4663E8", "E14B6A", "E0A22E", "3AA6A0", "8A5BE6", "FF7A3C"];
function hexToRgb(hex: string): [number, number, number] {
  return [parseInt(hex.slice(0, 2), 16) / 255, parseInt(hex.slice(2, 4), 16) / 255, parseInt(hex.slice(4, 6), 16) / 255];
}
/** Distinct world color by position — guarantees adjacent cards never collide. */
export function hueAt(i: number): [number, number, number] {
  return hexToRgb(COVER_HUES[((i % COVER_HUES.length) + COVER_HUES.length) % COVER_HUES.length]);
}
export function coverHue(seed: string | undefined | null): [number, number, number] {
  const s = seed ?? "";
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  const hex = COVER_HUES[Math.abs(h) % COVER_HUES.length];
  return [parseInt(hex.slice(0, 2), 16) / 255, parseInt(hex.slice(2, 4), 16) / 255, parseInt(hex.slice(4, 6), 16) / 255];
}

export function LivingCover({
  className = "",
  hue,
  style,
}: {
  className?: string;
  hue?: [number, number, number];
  style?: React.CSSProperties;
}) {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const gl = (canvas.getContext("webgl") ||
      canvas.getContext("experimental-webgl")) as WebGLRenderingContext | null;
    if (!gl) return;

    const prog = gl.createProgram()!;
    gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT));
    gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(prog);
    gl.useProgram(prog);

    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, "p");
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

    const uRes = gl.getUniformLocation(prog, "u_res");
    const uTime = gl.getUniformLocation(prog, "u_time");
    const uTone = gl.getUniformLocation(prog, "u_tone");
    const uHue = gl.getUniformLocation(prog, "u_hue");

    const size = () => {
      const d = Math.min(2, window.devicePixelRatio || 1);
      const w = canvas.clientWidth || 300;
      const h = canvas.clientHeight || 300;
      canvas.width = Math.max(1, Math.floor(w * d));
      canvas.height = Math.max(1, Math.floor(h * d));
      gl.viewport(0, 0, canvas.width, canvas.height);
    };
    size();
    const ro = new ResizeObserver(size);
    ro.observe(canvas);

    const tone = hue ? 3 : 0;
    const h = hue ?? [0.27, 0.39, 0.91];
    const start = performance.now();
    let raf = 0;
    const render = (now: number) => {
      gl.uniform2f(uRes, canvas.width, canvas.height);
      gl.uniform1f(uTime, (now - start) / 1000);
      gl.uniform1i(uTone, tone);
      gl.uniform3f(uHue, h[0], h[1], h[2]);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      raf = requestAnimationFrame(render);
    };
    raf = requestAnimationFrame(render);

    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
    };
  }, [hue ? hue.join(",") : ""]);

  return <canvas ref={ref} className={className} style={style} aria-hidden="true" />;
}
