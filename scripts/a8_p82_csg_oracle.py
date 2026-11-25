"""Independent local trilinear lattice CSG oracle. No calls to native brush."""
import math
from itertools import product

class Lattice:
    def __init__(self, data):
        self.lo=tuple(data["lo"])
        self.hi=tuple(data["hi"])
        if len(self.lo)!=3 or len(self.hi)!=3 or any(type(v)!=int for v in self.lo+self.hi):
            raise ValueError("invalid lattice bounds")
        self.shape=tuple(b-a+1 for a,b in zip(self.lo,self.hi))
        self.values=list(data["values"])
        if data["order"]!="zyx_x_fastest" or any(not 2<=n<=12 for n in self.shape) or len(self.values)!=math.prod(self.shape) or not all(type(v) in (int,float) and math.isfinite(v) for v in self.values):
            raise ValueError("invalid SDF lattice")

    def at(self,x,y,z):
        nx,ny,_=self.shape
        i,j,k=(x-self.lo[0],y-self.lo[1],z-self.lo[2])
        return self.values[(k*ny+j)*nx+i]

    def csg(self,center,radius,add):
        if len(center)!=3 or not all(math.isfinite(v) for v in center) or not 0<radius<=8 or type(add)!=bool:
            raise ValueError("invalid sphere")
        values=[]
        for z in range(self.lo[2],self.hi[2]+1):
            for y in range(self.lo[1],self.hi[1]+1):
                for x in range(self.lo[0],self.hi[0]+1):
                    sphere=math.dist((x,y,z),center)-radius
                    d=self.at(x,y,z)
                    values.append(min(d,sphere) if add else max(d,-sphere))
        return Lattice({"lo":list(self.lo),"hi":list(self.hi),"order":"zyx_x_fastest","values":values})

    def sample(self,p):
        if any(v<a-1e-8 or v>b+1e-8 for v,a,b in zip(p,self.lo,self.hi)):
            raise ValueError("outside lattice")
        q=[min(max(v,a),b) for v,a,b in zip(p,self.lo,self.hi)]
        i=[min(math.floor(v),b-1) for v,b in zip(q,self.hi)]
        f=[v-a for v,a in zip(q,i)]
        result=0.0
        for dx,dy,dz in product((0,1),repeat=3):
            w=math.prod(f[k] if bit else 1-f[k] for k,bit in enumerate((dx,dy,dz)))
            result+=w*self.at(i[0]+dx,i[1]+dy,i[2]+dz)
        return result

    def ray_interval(self,o,d):
        low,high=0.0,100.0
        for x,v,a,b in zip(o,d,self.lo,self.hi):
            if abs(v)<1e-10:
                if x<a or x>b:return None
            else:
                t,u=sorted(((a-x)/v,(b-x)/v))
                low,high=max(low,t),min(high,u)
                if low>=high:return None
        return low,high

    def first_hit(self,o,d):
        interval=self.ray_interval(o,d)
        if interval is None:return None
        lo,hi=interval
        def sample(t):return self.sample(tuple(a+t*b for a,b in zip(o,d)))
        if sample(lo)<=0:
            # The surface can be outside the sampled volume.
            return None
        previous=lo
        n=math.ceil((hi-lo)/0.025)
        for i in range(1,n+1):
            t=lo+(hi-lo)*i/n
            if sample(t)<=0:
                a,b=previous,t
                for _ in range(16):
                    m=(a+b)/2
                    if sample(m)>0:a=m
                    else:b=m
                return (a+b)/2
            previous=t
        return None

def predict(probe,pre,expected,actual,tolerance=0.45):
    o,d=probe["origin"],probe["direction"]
    before=probe["before_m"]
    if len(o)!=3 or len(d)!=3 or not all(math.isfinite(x) for x in o+d) or abs(math.sqrt(sum(x*x for x in d))-1)>0.002:
        raise ValueError("invalid ray")
    interval=pre.ray_interval(o,d)
    if interval is None or before is None or not math.isfinite(before):
        return {"status":"NO_LOCAL_BASELINE"}
    if before<=interval[0]+0.05 or before>=interval[1]-0.05:
        return {"status":"BASELINE_OUTSIDE_LATTICE"}
    p=pre.first_hit(o,d)
    if p is None or abs(p-before)>tolerance:
        return {"status":"PRE_REFERENCE_MISMATCH","oracle_before_m":p,"live_before_m":before}
    q=expected.first_hit(o,d)
    r=actual.first_hit(o,d)
    return {"status":"PREDICTED" if q is not None else "AFTER_OUTSIDE_LATTICE",
            "oracle_before_m":p,"oracle_after_m":q,"actual_lattice_after_m":r,
            "expected_actual_delta_m":None if q is None or r is None else abs(q-r)}

def evaluate(edit,radius):
    pre=Lattice(edit["pre_sdf_lattice"])
    actual=Lattice(edit["post_sdf_lattice"])
    if pre.lo!=actual.lo or pre.hi!=actual.hi:
        raise ValueError("lattice bounds differ")
    center=tuple(edit["center_"+k] for k in "xyz")
    expected=pre.csg(center,radius,edit["add"])
    # Compare signs outside a narrow zero-level ambiguity band.
    signs=[(a,b) for a,b in zip(expected.values,actual.values) if abs(a)>0.05 and abs(b)>0.05]
    return {"sign_comparisons":len(signs),"sign_disagreements":sum((a<0)!=(b<0) for a,b in signs),
            "rays":[predict(p,pre,expected,actual) for p in edit["probe_rays"]]}
