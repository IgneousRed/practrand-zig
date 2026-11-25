// Manual scalar precision audit of unchanged original source. No battery runs.
// Columns: case, input, original result, independent or asymptotic reference.
// Poisson peak references use a truncated Stirling series; see docs/precision-audit.md.
#include <cstdio>
#include <cmath>
#include <cfloat>
#include "src/math.cpp"
using namespace PractRand;
using namespace PractRand::Tests;
static void row(const char* name, double x, double got, double want) {
 std::printf("%s\t%.17g\t%.17g\t%.17g\n",name,x,got,want);
}
int main() {
 for(double z: {1e154,1.5e154,1.8e154})
  row("normal_logpdf",z,math_normaldist_pdf_log(z),-.9189385332046727-(z*.5)*z);
 int range_errors=0, drops=0; double previous=0, max_error=0;
 for(int i=0;i<=16000;i++) {
  double x=i*.01, got=math_chisquared_to_pvalue(x,1);
  double want=std::erf(std::sqrt(x/2));
  if(got<previous) ++drops;
  max_error=std::max(max_error,std::fabs(got-want)); previous=got;
  double c=math_normaldist_cdf(-x/10);
  if(c<0||c>1) ++range_errors;
 }
 std::printf("grid: chi1 drops=%d max_abs_error=%.17g normal_cdf_out_of_range=%d /16001\n",drops,max_error,range_errors);

 for(double z: {-11.,-10.,-9.,-8.,-7.,-6.,-5.,-3.,0.,3.,5.,6.,7.,8.,9.,10.,11.})
  row("normal_cdf",z,math_normaldist_cdf(z),.5*std::erfc(-z/std::sqrt(2.)));
 for(double z: {.01,.1,1.,2.,2.82842712474619,3.,5.,8.,12.,30.,1e154,1e155})
  row("normal_suspicion",z,math_normaldist_to_suspicion(z),-std::log2(std::erfc(z/std::sqrt(2.))));
 for(double x: {1e-20,1e-12,1e-8,.001,1.,10.,50.,100.,1000.}) {
  row("chi2_cdf",x,math_chisquared_to_pvalue(x,2),-std::expm1(-x/2));
  row("chi4_upper",x,1-math_chisquared_to_pvalue(x,4),std::exp(-x/2)*(1+x/2));
 }
 for(double x: {1.,4.,16.,36.,64.,100.,120.})
  row("chi1_cdf",x,math_chisquared_to_pvalue(x,1),std::erf(std::sqrt(x/2)));
 for(Uint64 n: {Uint64(1000),Uint64(1000000),Uint64(1000000000),Uint64(1000000000000),Uint64(1000000000000000)}) {
  Uint64 counts[2]={n+1,n-1}; double p[2]={.5,.5};
  double d=1./double(n);
  double stable=2*d + d*d*d/3;
  row("gtest_near_equal",double(n),g_test(2,p,counts),stable);
  row("gtest_flat_near_equal",double(n),g_test_flat(2,counts),stable);
  G_TEST g; g.add_category(counts[0], .5);g.add_category(counts[1], .5);g.finalize();
  row("G_TEST_near_equal",double(n),g.get_result(),stable);
 }
 for(int n: {1000,1000000,1000000000}) {
  double inv=1./n;
  double stable=std::exp(-.5*std::log(2*3.14159265358979323846*n)-inv/12+inv*inv*inv/360);
  row("poisson_peak",n,math_poisson_pmf(n,n),stable);
 }
 for(double x: {0.,1.,2.,10.}) row("upper_gamma2",x,math_upper_incomplete_gamma(2,x),std::exp(-x)*(1+x));
 for(int n: {5,6,10}) row("choose2",n,math_nChooseR(n,2),n*(n-1)/2.);
 double p=1e-20; row("gapuni_high_adjust",p,1-std::pow(1-p,1./16),-std::expm1(std::log1p(-p)/16));
}
