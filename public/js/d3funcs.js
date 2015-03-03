show_bargraph = function(datasource, title, xLabel, yLabel, yFormat, width, height) {

  var margin = {top: 40, right: 20, bottom: 40, left: 45};

  if (!width) {
    width = 960;
  }
  if (!height) {
    height = 500;
  }
  width -= margin.left + margin.right;
  height -= margin.top + margin.bottom;
  
  var x = d3.scale.ordinal()
      .rangeRoundBands([0, width], .1);
  
  var y = d3.scale.linear()
      .range([height, 0]);
  
  var xAxis = d3.svg.axis()
      .scale(x)
      .orient("bottom");
  
  var yAxis = d3.svg.axis()
      .scale(y)
      .orient("left");

  if (yFormat) {
      yAxis = yAxis.tickFormat(d3.format(yFormat));
  }
  
  var tip = d3.tip()
    .attr('class', 'd3-tip')
    .offset([-10, 0])
    .html(function(d) {
      if (d.y_matched == undefined) {
        return "n=<span style='color:orangered'>" + d.y_total + "</span>";
      }
      else {
        return "<span style='color:orangered'>" + d.y_matched + "</span> von " +
               "<span style='color:orangered'>" + d.y_total + "</span>";
      }
    });
  
  var svg = d3.select("body").append("svg")
      .attr("width", width + margin.left + margin.right)
      .attr("height", height + margin.top + margin.bottom)
    .append("g")
      .attr("transform", "translate(" + margin.left + "," + margin.top + ")");
  
  svg.call(tip);
  
  d3.tsv(datasource, type, function(error, data) {
    if (error) console.warn(error);
    x.domain(data.map(function(d) { return d.x; }));
    y.domain([0, d3.max(data, function(d) { return d.y; })]);
  
    svg.append("g")
        .attr("class", "x axis")
        .attr("transform", "translate(0," + height + ")")
        .call(xAxis)
      .append("text")
        .attr("x", width / 2)
        .attr("y", 30)
        .style("text-anchor", "middle")
        .text(xLabel);
  
    svg.append("g")
        .attr("class", "y axis")
        .call(yAxis)
      .append("text")
        .attr("transform", "rotate(-90)")
        .attr("y", 6)
        .attr("dy", ".71em")
        .style("text-anchor", "end")
        .text(yLabel);
  
    svg.append("text")
      .attr("x", (width / 2))
      .attr("y", 0 - (margin.top / 2))
      .attr("text-anchor", "middle")
      .style("font-size", "16px")
      .style("text-decoration", "underline")
      .text(title);
  
    svg.selectAll(".bar")
        .data(data)
      .enter().append("rect")
        .attr("class", "bar")
        .attr("x", function(d) { return x(d.x); })
        .attr("width", x.rangeBand())
        .attr("y", function(d) { return y(d.y); })
        .attr("height", function(d) { return height - y(d.y); })
        .on('mouseover', tip.show)
        .on('mouseout', tip.hide)
  
  });
  
  function type(d) {
    d.y = +d.y;
    return d;
  }
};

show_piechart = function(datasource, title, yFormat, width, height) {

  var margin = {top: 40, right: 20, bottom: 30, left: 40};

  if (!width) {
    width = 960;
  }
  if (!height) {
    height = 500;
  }
  width -= margin.left + margin.right;
  height -= margin.top + margin.bottom;

  var width = 960,
      height = 500,
      radius = Math.min(width, height) / 2;
  
  var color = d3.scale.ordinal()
      .range(["#98abc5", "#8a89a6", "#7b6888", "#6b486b", "#a05d56", "#d0743c", "#ff8c00"]);
  
  var arc = d3.svg.arc()
      .outerRadius(radius - 10)
      .innerRadius(0);
  
  var pie = d3.layout.pie()
      .sort(null)
      .value(function(d) { return d.y; });
  
  var svg = d3.select("body").append("svg")
      .attr("width", width)
      .attr("height", height)
    .append("g")
      .attr("transform", "translate(" + width / 2 + "," + height / 2 + ")");
  
  d3.tsv(datasource, function(error, data) {
  
    data.forEach(function(d) {
      d.y = +d.y;
    });
  
    var g = svg.selectAll(".arc")
        .data(pie(data))
      .enter().append("g")
        .attr("class", "arc");
  
    g.append("path")
        .attr("d", arc)
        .style("fill", function(d) { return color(d.data.x); });
  
    g.append("text")
        .attr("transform", function(d) { return "translate(" + arc.centroid(d) + ")"; })
        .attr("dy", ".35em")
        .style("text-anchor", "middle")
        .text(function(d) { return d.data.x; });
  
  });
};
