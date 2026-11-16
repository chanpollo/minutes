namespace Minutes.Core;

public static class AudioAnalysis
{
    public const double LeakThreshold=.2;
    public static double Leak(IReadOnlyList<double> a,IReadOnlyList<double> b)
    {
        var count=Math.Min(a.Count,b.Count);if(count<=100)return 0;var best=0d;
        for(var lag=-10;lag<=10;lag++)
        {
            var x=a.Skip(Math.Max(0,lag)).Take(count+Math.Min(0,lag)-Math.Max(0,lag)).ToArray();
            var y=b.Skip(Math.Max(0,-lag)).Take(count-Math.Max(0,lag)-Math.Max(0,-lag)).ToArray();best=Math.Max(best,Correlation(x,y));
        }
        return best;
    }
    public static double Correlation(IReadOnlyList<double> x,IReadOnlyList<double> y)
    {
        if(x.Count!=y.Count||x.Count==0)return 0;var mx=x.Average();var my=y.Average();double sxy=0,sxx=0,syy=0;
        for(var i=0;i<x.Count;i++){var dx=x[i]-mx;var dy=y[i]-my;sxy+=dx*dy;sxx+=dx*dx;syy+=dy*dy;}
        return sxx>0&&syy>0?sxy/Math.Sqrt(sxx*syy):0;
    }
}
