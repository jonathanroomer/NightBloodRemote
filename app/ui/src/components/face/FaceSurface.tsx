import { useEffect, useState } from "react";

import { FaceCanvas, type FaceCanvasProps } from "./FaceCanvas";
import type { FaceSkin } from "./faceSkin";
import { MarshmallowCanvas } from "./MarshmallowCanvas";

export interface FaceSurfaceProps extends FaceCanvasProps {
  readonly skin: FaceSkin;
}

function useReducedMotion(explicit: boolean | undefined): boolean {
  const [system, setSystem] = useState(() =>
    typeof window !== "undefined"
      && window.matchMedia("(prefers-reduced-motion: reduce)").matches);

  useEffect(() => {
    const media = window.matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => setSystem(media.matches);
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);

  return explicit ?? system;
}

/** Switches appearance only; state authority and input provenance stay shared. */
export function FaceSurface({ skin, reducedMotion, ...props }: FaceSurfaceProps) {
  const reduce = useReducedMotion(reducedMotion);
  return skin === "marshmallow"
    ? <MarshmallowCanvas {...props} reducedMotion={reduce} />
    : <FaceCanvas {...props} reducedMotion={reduce} />;
}
